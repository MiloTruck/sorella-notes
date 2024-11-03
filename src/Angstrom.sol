// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {EIP712} from "solady/src/utils/EIP712.sol";
import {TopLevelAuth} from "./modules/TopLevelAuth.sol";
import {Settlement} from "./modules/Settlement.sol";
import {PoolUpdates} from "./modules/PoolUpdates.sol";
import {OrderInvalidation} from "./modules/OrderInvalidation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {UniConsumer} from "./modules/UniConsumer.sol";
import {PermitSubmitterHook} from "./modules/PermitSubmitterHook.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {CalldataReader, CalldataReaderLib} from "./types/CalldataReader.sol";
import {AssetArray, AssetLib} from "./types/Asset.sol";
import {PairArray, PairLib} from "./types/Pair.sol";
import {TypedDataHasher, TypedDataHasherLib} from "./types/TypedDataHasher.sol";
import {HookBuffer, HookBufferLib} from "./types/HookBuffer.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";
import {
    PriceAB as PriceOutVsIn, AmountA as AmountOut, AmountB as AmountIn
} from "./types/Price.sol";
import {ToBOrderBuffer} from "./types/ToBOrderBuffer.sol";
import {ToBOrderVariantMap} from "./types/ToBOrderVariantMap.sol";
import {UserOrderBuffer} from "./types/UserOrderBuffer.sol";
import {UserOrderVariantMap} from "./types/UserOrderVariantMap.sol";

/// @author philogy <https://github.com/philogy>
contract Angstrom is
    EIP712,
    OrderInvalidation,
    Settlement,
    TopLevelAuth,
    PoolUpdates,
    IUnlockCallback,
    PermitSubmitterHook
{
    error LimitViolated();
    error ToBGasUsedAboveMax();

    constructor(IPoolManager uniV4, address controller, address feeMaster)
        UniConsumer(uniV4)
        TopLevelAuth(controller)
        Settlement(feeMaster)
    {
        _checkAngstromHookFlags();
    }

    function execute(bytes calldata encoded) external {
        _nodeBundleLock();
        UNI_V4.unlock(encoded);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        _onlyUniV4();

        CalldataReader reader = CalldataReaderLib.from(data);

        AssetArray assets;
        (reader, assets) = AssetLib.readFromAndValidate(reader);
        PairArray pairs;
        (reader, pairs) = PairLib.readFromAndValidate(reader, assets, _configStore);

        _takeAssets(assets);
        reader = _updatePools(reader, pairs);
        reader = _validateAndExecuteToBOrders(reader, pairs);
        reader = _validateAndExecuteUserOrders(reader, pairs);
        reader.requireAtEndOf(data);
        _saveAndSettle(assets);

        // Return empty bytes.
        assembly ("memory-safe") {
            mstore(0x00, 0x20) // Dynamic type relative offset
            mstore(0x20, 0x00) // Bytes length
            return(0x00, 0x40)
        }
    }

    /// @dev Load arbitrary storage slot from this contract, enables on-chain introspection without
    /// view methods.
    function extsload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0x00, sload(slot))
            return(0x00, 0x20)
        }
    }

    function _validateAndExecuteToBOrders(CalldataReader reader, PairArray pairs)
        internal
        returns (CalldataReader)
    {
        CalldataReader end;
        (reader, end) = reader.readU24End();

        TypedDataHasher typedHasher = _erc712Hasher();
        ToBOrderBuffer memory buffer;
        buffer.init();

        // Purposefully devolve into an endless loop if the specified length isn't exactly used s.t.
        // `reader == end` at some point.
        while (reader != end) {
            reader = _validateAndExecuteToBOrder(reader, buffer, typedHasher, pairs);
        }

        return reader;
    }

    /*
    @note Data read from calldata:

    uuint8 variantByte
    uint128 quantityIn
    uint128 quantityOut
    uint128 maxGasAsset0
    uint128 gasUsedAsset0
    uint16 pairIndex
    address? recipient
    bytes65? signature 
    address? from
    bytes? signature

    If variantMap.recipientIsSome() == true, the recipient address is specified in calldata. Otherwise, tokens
    are sent to the from address.

    If variantMap.isEcdsa() == true, bytes65 signature is read and the from address is the signer recovered
    from the signature. Otherwise, (address from | bytes signature) is read. 
    */
    function _validateAndExecuteToBOrder(
        CalldataReader reader,
        ToBOrderBuffer memory buffer,
        TypedDataHasher typedHasher,
        PairArray pairs
    ) internal returns (CalldataReader) {
        // Load `TopOfBlockOrder` PADE variant map which will inform later variable-type encoding.
        ToBOrderVariantMap variantMap;
        {
            uint8 variantByte;
            (reader, variantByte) = reader.readU8();
            variantMap = ToBOrderVariantMap.wrap(variantByte);
        }

        buffer.useInternal = variantMap.useInternal();

        (reader, buffer.quantityIn) = reader.readU128();
        (reader, buffer.quantityOut) = reader.readU128();
        (reader, buffer.maxGasAsset0) = reader.readU128();
        // Decode, validate & apply gas fee.
        {
            uint128 gasUsedAsset0;
            (reader, gasUsedAsset0) = reader.readU128();
            if (gasUsedAsset0 > buffer.maxGasAsset0) revert ToBGasUsedAboveMax();
            if (variantMap.zeroForOne()) {
                buffer.quantityIn += gasUsedAsset0;
            } else {
                buffer.quantityOut -= gasUsedAsset0;
            }
        }

        {
            uint16 pairIndex;
            (reader, pairIndex) = reader.readU16();
            (buffer.assetIn, buffer.assetOut) =
                pairs.get(pairIndex).getAssets(variantMap.zeroForOne());
        }

        (reader, buffer.recipient) =
            variantMap.recipientIsSome() ? reader.readAddr() : (reader, address(0));

        bytes32 orderHash = typedHasher.hashTypedData(buffer.hash());
        /*
        @audit Is anything missing from orderHash?

        orderHash is validated against the signature provided by the user. If anything is missing, the node
        can freely manipulate the ToB order.

        variantMap.isEcdsa() can be manipulated to use ERC1271 instead of ECDSA (and vice versa) by the node,
        however, signature verification below shouldn't pass if it is manipulated.
        */

        _invalidateOrderHash(orderHash);
        /*
        @audit-issue Spearbit issue 5.3.5

        There might be multiple legitimate orders with the same orderHash in the same block.
        */

        address from;
        (reader, from) = variantMap.isEcdsa()
            ? SignatureLib.readAndCheckEcdsa(reader, orderHash)
            : SignatureLib.readAndCheckERC1271(reader, orderHash);
        /*
        @audit Differences from typical implementations.

        Unlike typical implementations where the from address is specified and the signer recovered from ECDSA
        is checked against the from address, the signer here is used directly.

        Instead of checking is the from address is an EOA/contract and deciding to use ECDSA/ERC1271 based on
        that, the node can specify how the signature is verified. This makes it possible to use ECDSA for a
        contract address and ERC1271 for an EOA. 

        Could any issues arise from these differences?
        */

        address to = buffer.recipient;
        assembly {
            to := or(mul(iszero(to), from), to)
        }
        /*
        @note This is equivalent to:

        to == 0 -> to = from
        to != 0 -> to = to

        if (to == 0) to = from

        This makes it not possible to have the to address as address(0).
        */

        _settleOrderIn(
            from, buffer.assetIn, AmountIn.wrap(buffer.quantityIn), variantMap.useInternal()
        );
        _settleOrderOut(
            to, buffer.assetOut, AmountOut.wrap(buffer.quantityOut), variantMap.useInternal()
        );

        return reader;
    }

    function _validateAndExecuteUserOrders(CalldataReader reader, PairArray pairs)
        internal
        returns (CalldataReader)
    {
        TypedDataHasher typedHasher = _erc712Hasher();
        UserOrderBuffer memory buffer;

        CalldataReader end;
        (reader, end) = reader.readU24End();

        // Purposefully devolve into an endless loop if the specified length isn't exactly used s.t.
        // `reader == end` at some point.
        while (reader != end) {
            reader = _validateAndExecuteUserOrder(reader, buffer, typedHasher, pairs);
        }

        return reader;
    }

    /*
    @note Data read from calldata:

    bytes1 variantMap
    uint32 refId
    uint16 pairIndex
    uint256 minPrice
    address? recipient
    uint24 hookDataLength
    bytes hookData
    uint64? nonce
    uint40? deadline
    uint128? minQuantityIn
    uint128? maxQuantityIn
    uint128 quantity
    uint128 maxExtraFeeAsset0
    uint128 extraFeeAsset0
    bytes65? signature
    address? from
    bytes? signature

    If variantMap.recipientIsSome() == true, the recipient address is specified in calldata. Otherwise, tokens
    are sent to the from address.

    If variantMap.isStanding() == true (ie. standing orders), nonce and deadline are specified.

    If variant.quantitiesPartial() == true, minQuantityIn and maxQuantityIn are specified.

    If isEcdsa(), bytes65 signature is read. from is taken as the signer recovered from the signature
    otherwise, (address from | bytes signature) is read. 
    */
    function _validateAndExecuteUserOrder(
        CalldataReader reader,
        UserOrderBuffer memory buffer,
        TypedDataHasher typedHasher,
        PairArray pairs
    ) internal returns (CalldataReader) {
        UserOrderVariantMap variantMap;
        // Load variant map, ref id and set use internal.
        (reader, variantMap) = buffer.init(reader);

        // Load and lookup asset in/out and dependent values.
        PriceOutVsIn price;
        {
            uint256 priceOutVsIn;
            uint16 pairIndex;
            (reader, pairIndex) = reader.readU16();
            (buffer.assetIn, buffer.assetOut, priceOutVsIn) =
                pairs.get(pairIndex).getSwapInfo(variantMap.zeroForOne());
            price = PriceOutVsIn.wrap(priceOutVsIn);
        }

        (reader, buffer.minPrice) = reader.readU256();
        if (price.into() < buffer.minPrice) revert LimitViolated();

        (reader, buffer.recipient) =
            variantMap.recipientIsSome() ? reader.readAddr() : (reader, address(0));

        HookBuffer hook;
        (reader, hook, buffer.hookDataHash) = HookBufferLib.readFrom(reader, variantMap.noHook());

        // For flash orders sets the current block number as `validForBlock` so that it's
        // implicitly validated via hashing later.
        reader = buffer.readOrderValidation(reader, variantMap);

        AmountIn amountIn;
        AmountOut amountOut;
        (reader, amountIn, amountOut) = buffer.loadAndComputeQuantity(reader, variantMap, price);

        bytes32 orderHash = typedHasher.hashTypedData(buffer.structHash(variantMap));
        /*
        @audit Is anything missing from orderHash?

        variantMap.isEcdsa() can be manipulated to use ERC1271 instead of ECDSA (and vice versa) by the node,
        however, signature verification below shouldn't pass if it is manipulated.

        UserBufferOrder.deadline_or_empty isn't set if isStanding() == false, but that's fine as it's not used
        for flash orders. It's always set for standing orders when used.
        */

        address from;
        (reader, from) = variantMap.isEcdsa()
            ? SignatureLib.readAndCheckEcdsa(reader, orderHash)
            : SignatureLib.readAndCheckERC1271(reader, orderHash);

        if (variantMap.isStanding()) {
            _checkDeadline(buffer.deadline_or_empty);
            _invalidateNonce(from, buffer.nonce_or_validForBlock);
        } else {
            _invalidateOrderHash(orderHash);
            /*
            @audit-issue Spearbit issue 5.3.5

            There might be multiple legitimate orders with the same orderHash in the same block.
            */
        }

        // Push before hook as a potential loan.
        address to = buffer.recipient;
        assembly {
            to := or(mul(iszero(to), from), to)
        }
        /*
        @note This is equivalent to:

        to == 0 -> to = from
        to != 0 -> to = to

        if (to == 0) to = from

        This makes it not possible to have the to address as address(0).
        */

        _settleOrderOut(to, buffer.assetOut, amountOut, variantMap.useInternal());

        hook.tryTrigger(from);
        /*
        @audit Untrusted external call.

        For user orders, hookAddr can be freely specified by the user. Can a user exploit this to call a
        malicious contract and perform anything he shouldn't be able to? eg. reentrancy
        */

        _settleOrderIn(from, buffer.assetIn, amountIn, variantMap.useInternal());
        /*
        @audit Inflow/outflow sequence is swapped for user orders.
        
        For user orders, outflows are performed before inflows. Whereas in ToB orders, inflows are settled
        before outflows. Does this matter?
        */

        return reader;
    }

    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory, string memory)
    {
        return ("Angstrom", "v1");
    }

    function _erc712Hasher() internal view returns (TypedDataHasher) {
        return TypedDataHasherLib.init(_domainSeparator());
    }
}
