pragma solidity ^0.5.4;
import "../wallet/BaseWallet.sol";
import "./common/BaseModule.sol";
import "./common/RelayerModule.sol";
import "./common/LimitManager.sol";
import "../exchange/TokenPriceProvider.sol";
import "../storage/GuardianStorage.sol";
import "../storage/TransferStorage.sol";

/**
 * @title TransferManager
 * @dev Module to transfer tokens (ETH or ERC20) or data (contract call) based on a security context (daily limit, whitelist, etc).
 * @author Julien Niset - <julien@argent.xyz>
 */
contract TransferManager is BaseModule, RelayerModule, LimitManager {

    bytes32 constant NAME = "TransferManager";
    

    bytes4 constant internal EXECUTE_PENDING_PREFIX = bytes4(keccak256("executePendingTransfer(address,address,address,uint256,bytes,uint256)"));

    bytes4 private constant ERC20_TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant ERC20_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant ERC721_ISVALIDSIGNATURE_BYTES = bytes4(keccak256("isValidSignature(bytes,bytes)"));
    bytes4 private constant ERC721_ISVALIDSIGNATURE_BYTES32 = bytes4(keccak256("isValidSignature(bytes32,bytes)"));

    bytes constant internal EMPTY_BYTES = "";

    enum ActionType { Transfer, Approve, CallContract }

    using SafeMath for uint256;

    // Mock token address for ETH
    address constant internal ETH_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct TokenManagerConfig {
        // Mapping between pending action hash and their timestamp
        mapping (bytes32 => uint256) pendingActions;
    }

    // wallet specific storage
    mapping (address => TokenManagerConfig) internal configs;

    // The security period
    uint256 public securityPeriod;
    // The execution window
    uint256 public securityWindow;
    // The Guardian storage
    GuardianStorage public guardianStorage;
    // The Token storage
    TransferStorage public transferStorage;
    // The Token price provider
    TokenPriceProvider public priceProvider;
    // The previous limit manager needed to migrate the limits
    LimitManager public oldLimitManager;

    // *************** Events *************************** //

    event Transfer(address indexed wallet, address indexed token, uint256 indexed amount, address to, bytes data);
    event Approved(address indexed wallet, address indexed token, uint256 indexed amount, address spender);
    event CalledContract(address indexed wallet, address indexed to, uint256 indexed amount, bytes data);
    event AddedToWhitelist(address indexed wallet, address indexed target, uint64 whitelistAfter);
    event RemovedFromWhitelist(address indexed wallet, address indexed target);
    event PendingTransferCreated(address indexed wallet, bytes32 indexed id, uint256 indexed executeAfter, address token, address to, uint256 amount, bytes data);
    event PendingTransferExecuted(address indexed wallet, bytes32 indexed id);
    event PendingTransferCanceled(address indexed wallet, bytes32 indexed id);
    event PendingApproveCreated(address indexed wallet, bytes32 indexed id, uint256 indexed executeAfter, address token, address spender, uint256 amount);
    event PendingApproveExecuted(address indexed wallet, bytes32 indexed id);
    event PendingApproveCanceled(address indexed wallet, bytes32 indexed id);
    event PendingCallContractCreated(address indexed wallet, bytes32 indexed id, uint256 indexed executeAfter, address _contract, uint256 amount, bytes data);
    event PendingCallContractExecuted(address indexed wallet, bytes32 indexed id);
    event PendingCallContractCanceled(address indexed wallet, bytes32 indexed id);

    // *************** Modifiers *************************** //

    /**
     * @dev Throws if the wallet is locked.
     */
    modifier onlyWhenUnlocked(BaseWallet _wallet) {
        // solium-disable-next-line security/no-block-members
        require(!guardianStorage.isLocked(_wallet), "TT: wallet must be unlocked");
        _;
    }

    // *************** Constructor ********************** //

    constructor(
        ModuleRegistry _registry,
        TransferStorage _transferStorage,
        GuardianStorage _guardianStorage,
        address _priceProvider,
        uint256 _securityPeriod,
        uint256 _securityWindow,
        uint256 _defaultLimit,
        LimitManager _oldLimitManager
    )
        BaseModule(_registry, NAME)
        LimitManager(_defaultLimit)
        public
    {
        transferStorage = _transferStorage;
        guardianStorage = _guardianStorage;
        priceProvider = TokenPriceProvider(_priceProvider);
        securityPeriod = _securityPeriod;
        securityWindow = _securityWindow;
        oldLimitManager = _oldLimitManager;
    }

    /**
     * @dev Inits the module for a wallet by setting up the isValidSignature (EIP 1271)
     * static call redirection from the wallet to the module and copying all the parameters
     * of the daily limit from the previous implementation of the LimitManager module.
     * @param _wallet The target wallet.
     */
    function init(BaseWallet _wallet) external onlyWallet(_wallet) {
        // setup static calls
        _wallet.enableStaticCall(address(this), ERC721_ISVALIDSIGNATURE_BYTES);
        _wallet.enableStaticCall(address(this), ERC721_ISVALIDSIGNATURE_BYTES32);
        // copy limit parameters
        if(address(oldLimitManager) != address(0)) {
            uint256 currentLimit = oldLimitManager.getCurrentLimit(_wallet);
            (uint256 pendingLimit, uint64 changeAfter) = oldLimitManager.getPendingLimit(_wallet);
            (uint256 unspent, uint64 periodEnd) = oldLimitManager.getDailyUnspent(_wallet);
            // check if there is a pending limit
            if(currentLimit == pendingLimit) {
                limits[address(_wallet)].limit.current = uint128(currentLimit);
            }
            else {
                limits[address(_wallet)].limit = Limit(uint128(currentLimit), uint128(pendingLimit), changeAfter);
            }
            // check if we are within a rolling period
            if(periodEnd > now) {
                limits[address(_wallet)].dailySpent = DailySpent(uint128(currentLimit.sub(unspent)), periodEnd);
            }
        }
    }

    // *************** External/Public Functions ********************* //

    /**
    * @dev lets the owner transfer tokens (ETH or ERC20) from a wallet.
    * @param _wallet The target wallet.
    * @param _token The address of the token to transfer.
    * @param _to The destination address
    * @param _amount The amoutn of token to transfer
    * @param _data The data for the transaction
    */
    function transferToken(
        BaseWallet _wallet,
        address _token,
        address _to,
        uint256 _amount,
        bytes calldata _data
    )
        external
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        if(isWhitelisted(_wallet, _to)) {
            // transfer to whitelist
            doTransfer(_wallet, _token, _to, _amount, _data);
        }
        else {
            uint256 etherAmount = (_token == ETH_TOKEN) ? _amount : priceProvider.getEtherValue(_amount, _token);
            if (checkAndUpdateDailySpent(_wallet, etherAmount)) {
                // transfer under the limit
                doTransfer(_wallet, _token, _to, _amount, _data);
            }
            else {
                // transfer above the limit
                (bytes32 id, uint256 executeAfter) = addPendingAction(ActionType.Transfer, _wallet, _token, _to, _amount, _data);
                emit PendingTransferCreated(address(_wallet), id, executeAfter, _token, _to, _amount, _data);
            }
        }
    }

    function approveTranfer(
        BaseWallet _wallet,
        address _token,
        address _spender,
        uint256 _amount
    )
        external
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        if(isWhitelisted(_wallet, _spender)) {
            // approve to whitelist
            doApproveTransfer(_wallet, _token, _spender, _amount);
        }
        else {
            uint256 etherAmount = priceProvider.getEtherValue(_amount, _token);
            if (checkAndUpdateDailySpent(_wallet, etherAmount)) {
                // approve under the limit
                doApproveTransfer(_wallet, _token, _spender, _amount);
            }
            else {
                // approve above the limit
                (bytes32 id, uint256 executeAfter) = addPendingAction(ActionType.Approve, _wallet, _token, _spender, _amount, EMPTY_BYTES);
                emit PendingApproveCreated(address(_wallet), id, executeAfter, _token, _spender, _amount);
            }
        }
    }

    function callContract(
        BaseWallet _wallet,
        address _contract,
        uint256 _value,
        bytes calldata _data
    )
        external
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        if(isWhitelisted(_wallet, _contract)) {
            // call to whitelist
            doCallContract(_wallet, _contract, _value, _data);
        }
        else {
            if (checkAndUpdateDailySpent(_wallet, _value)) {
                // call under the limit
                doCallContract(_wallet, _contract, _value, _data);
            }
            else {
                // call above the limit
                (bytes32 id, uint256 executeAfter) = addPendingAction(ActionType.CallContract, _wallet, address(0), _contract, _value, _data);
                emit PendingCallContractCreated(address(_wallet), id, executeAfter, _contract, _value, _data);
            }
        }
    }

    /**
     * @dev Adds an address to the whitelist of a wallet.
     * @param _wallet The target wallet.
     * @param _target The address to add.
     */
    function addToWhitelist(
        BaseWallet _wallet,
        address _target
    )
        external
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        require(!isWhitelisted(_wallet, _target), "TT: target already whitelisted");
        // solium-disable-next-line security/no-block-members
        uint256 whitelistAfter = now.add(securityPeriod);
        transferStorage.setWhitelist(_wallet, _target, whitelistAfter);
        emit AddedToWhitelist(address(_wallet), _target, uint64(whitelistAfter));
    }

    /**
     * @dev Removes an address from the whitelist of a wallet.
     * @param _wallet The target wallet.
     * @param _target The address to remove.
     */
    function removeFromWhitelist(
        BaseWallet _wallet,
        address _target
    )
        external
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        require(isWhitelisted(_wallet, _target), "TT: target not whitelisted");
        transferStorage.setWhitelist(_wallet, _target, 0);
        emit RemovedFromWhitelist(address(_wallet), _target);
    }

    function executePendingTransfer(
        BaseWallet _wallet,
        address _token,
        address _to,
        uint _amount,
        bytes memory _data,
        uint _block
    )
        public
        onlyWhenUnlocked(_wallet)
    {
        bytes32 id = executePendingAction(_wallet, ActionType.Transfer, _token, _to, _amount, _data, _block);
        emit PendingTransferExecuted(address(_wallet), id);
    }

    function cancelPendingTransfer(
        BaseWallet _wallet,
        bytes32 _id
    )
        public
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        cancelPendingAction(_wallet, _id);
        emit PendingTransferCanceled(address(_wallet), _id);
    }

    function executePendingApprove(
        BaseWallet _wallet,
        address _token,
        address _spender,
        uint _amount,
        uint _block
    )
        public
        onlyWhenUnlocked(_wallet)
    {
        bytes32 id = executePendingAction(_wallet, ActionType.Approve, _token, _spender, _amount, EMPTY_BYTES, _block);
        emit PendingApproveExecuted(address(_wallet), id);
    }

    function cancelPendingApprove(
        BaseWallet _wallet,
        bytes32 _id
    )
        public
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        cancelPendingAction(_wallet, _id);
        emit PendingApproveCanceled(address(_wallet), _id);
    }

    function executePendingCallContract(
        BaseWallet _wallet,
        address _contract,
        uint _amount,
        bytes memory _data,
        uint _block
    )
        public
        onlyWhenUnlocked(_wallet)
    {
        bytes32 id = executePendingAction(_wallet, ActionType.CallContract, address(0), _contract, _amount, _data, _block);
        emit PendingCallContractExecuted(address(_wallet), id);
    }

    function cancelPendingCallContract(
        BaseWallet _wallet,
        bytes32 _id
    )
        public
        onlyWalletOwner(_wallet)
        onlyWhenUnlocked(_wallet)
    {
        cancelPendingAction(_wallet, _id);
        emit PendingCallContractCanceled(address(_wallet), _id);
    }

    /**
     * @dev Lets the owner of a wallet change its global limit.
     * The limit is expressed in ETH. Changes to the limit take 24 hours.
     * @param _wallet The target wallet.
     * @param _newLimit The new limit.
     */
    function changeLimit(BaseWallet _wallet, uint256 _newLimit) public onlyWalletOwner(_wallet) onlyWhenUnlocked(_wallet) {
        changeLimit(_wallet, _newLimit, securityPeriod);
    }

    /**
     * @dev Convenience method to disable the limit
     * The limit is disabled by setting it to an arbitrary large value.
     * @param _wallet The target wallet.
     */
    function disableLimit(BaseWallet _wallet) external onlyWalletOwner(_wallet) onlyWhenUnlocked(_wallet) {
        changeLimit(_wallet, LIMIT_DISABLED, securityPeriod);
    }

    /**
    * @dev Checks if an address is whitelisted for a wallet.
    * @param _wallet The target wallet.
    * @param _target The address.
    * @return true if the address is whitelisted.
    */
    function isWhitelisted(BaseWallet _wallet, address _target) public view returns (bool _isWhitelisted) {
        uint whitelistAfter = transferStorage.getWhitelist(_wallet, _target);
        // solium-disable-next-line security/no-block-members
        return whitelistAfter > 0 && whitelistAfter < now;
    }

    /**
    * @dev Gets the info of a pending action for a wallet.
    * @param _wallet The target wallet.
    * @param _id The pending action ID.
    * @return the epoch time at which the pending action can be executed.
    */
    function getPendingAction(BaseWallet _wallet, bytes32 _id) external view returns (uint64 _executeAfter) {
        _executeAfter = uint64(configs[address(_wallet)].pendingActions[_id]);
    }

    /**
    * @dev Implementation of EIP 1271.
    * Should return whether the signature provided is valid for the provided data.
    * @param _data Arbitrary length data signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _data
    */
    function isValidSignature(bytes memory _data, bytes memory _signature) public view returns (bytes4) {
        bytes32 msgHash = keccak256(abi.encodePacked(_data));
        isValidSignature(msgHash, _signature);
        return ERC721_ISVALIDSIGNATURE_BYTES;
    }

    /**
    * @dev Implementation of EIP 1271.
    * Should return whether the signature provided is valid for the provided data.
    * @param _msgHash Hash of a message signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _msgHash
    */
    function isValidSignature(bytes32 _msgHash, bytes memory _signature) public view returns (bytes4) {
        require(_signature.length == 65, "TM: invalid signature length");
        address signer = recoverSigner(_msgHash, _signature, 0);
        require(isOwner(BaseWallet(msg.sender), signer), "TM: Invalid signer");
        return ERC721_ISVALIDSIGNATURE_BYTES32;
    }

    // *************** Internal Functions ********************* //

    /**
    * @dev Helper method to transfer ETH or ERC20 for a wallet.
    * @param _wallet The target wallet.
    * @param _token The ERC20 address.
    * @param _to The recipient.
    * @param _value The amount of ETH to transfer
    * @param _data The data to *log* with the transfer.
    */
    function doTransfer(BaseWallet _wallet, address _token, address _to, uint256 _value, bytes memory _data) internal {
        if(_token == ETH_TOKEN) {
            _wallet.invoke(_to, _value, EMPTY_BYTES);
        }
        else {
            bytes memory methodData = abi.encodeWithSignature("transfer(address,uint256)", _to, _value);
            _wallet.invoke(_token, 0, methodData);
        }
        emit Transfer(address(_wallet), _token, _value, _to, _data);
    }

    /**
    * @dev Helper method to approve spending the ERC20 of a wallet.
    * @param _wallet The target wallet.
    * @param _token The ERC20 address.
    * @param _spender The spender address.
    * @param _value The amount of token to transfer.
    */
    function doApproveTransfer(BaseWallet _wallet, address _token, address _spender, uint256 _value) internal {
        bytes memory methodData = abi.encodeWithSignature("approve(address,uint256)", _spender, _value);
        _wallet.invoke(_token, 0, methodData);
        emit Approved(address(_wallet), _token, _value, _spender);
    }

    /**
    * @dev Helper method to call an external contract.
    * @param _wallet The target wallet.
    * @param _contract The contract address.
    * @param _value The ETH value to transfer.
    * @param _data The method data.
    */
    function doCallContract(BaseWallet _wallet, address _contract, uint256 _value, bytes memory _data) internal {
        bytes4 methodId = functionPrefix(_data);
        require(methodId != ERC20_TRANSFER && methodId != ERC20_APPROVE, "TM: Forbidden method");
        _wallet.invoke(_contract, _value, _data);
        emit CalledContract(address(_wallet), _contract, _value, _data);
    }

    /**
     * @dev Creates a new pending action for a wallet.
     * @param _action The target action.
     * @param _wallet The target wallet.
     * @param _token The target token for the action.
     * @param _to The recipient of the action.
     * @param _amount The amount of token associated to the action.
     * @param _data The data associated to the action.
     * @return the identifier for the new pending action and the time when the action can be executed
     */
    function addPendingAction(
        ActionType _action,
        BaseWallet _wallet,
        address _token,
        address _to,
        uint _amount,
        bytes memory _data
    )
        internal
        returns (bytes32 id, uint256 executeAfter)
    {
        id = keccak256(abi.encodePacked(_action, _token, _to, _amount, _data, block.number));
        require(configs[address(_wallet)].pendingActions[id] == 0, "TM: duplicate pending action");
        executeAfter = now.add(securityPeriod);
        configs[address(_wallet)].pendingActions[id] = executeAfter;
    }

    /**
    * @dev Executes a pending transfer for a wallet.
    * The destination address is automatically added to the whitelist.
    * The method can be called by anyone to enable orchestration.
    * @param _wallet The target wallet.
    * @param _action The target action.
    * @param _token The token of the pending transfer.
    * @param _to The destination address of the pending transfer.
    * @param _amount The amount of token to transfer of the pending transfer.
    * @param _block The block at which the pending transfer was created.
    */
    function executePendingAction(
        BaseWallet _wallet,
        ActionType _action,
        address _token,
        address _to,
        uint _amount,
        bytes memory _data,
        uint _block
    )
        internal
        returns (bytes32 id)
    {
        id = keccak256(abi.encodePacked(_action, _token, _to, _amount, _data, _block));
        uint executeAfter = configs[address(_wallet)].pendingActions[id];
        uint executeBefore = executeAfter.add(securityWindow);
        require(executeAfter <= now && now <= executeBefore, "TT: action outside of the execution window");
        delete configs[address(_wallet)].pendingActions[id];
        if(_action == ActionType.Transfer) {
            doTransfer(_wallet, _token, _to, _amount, _data);
        }
        else if(_action == ActionType.Approve) {
            doApproveTransfer(_wallet, _token, _to, _amount);
        }
        else if(_action == ActionType.CallContract) {
            doCallContract(_wallet, _to, _amount, _data);
        }
        else {
            revert("TM: unknown action");
        }
    }

    /**
    * @dev Cancels a pending action for a wallet.
    * @param _wallet The target wallet.
    * @param _id the pending action ID.
    */
    function cancelPendingAction(
        BaseWallet _wallet,
        bytes32 _id
    )
        internal
    {
        require(configs[address(_wallet)].pendingActions[_id] > 0, "TT: unknown pending action");
        delete configs[address(_wallet)].pendingActions[_id];
    }

    // *************** Implementation of RelayerModule methods ********************* //

    // Overrides refund to add the refund in the daily limit.
    function refund(BaseWallet _wallet, uint _gasUsed, uint _gasPrice, uint _gasLimit, uint _signatures, address _relayer) internal {
        // 21000 (transaction) + 7620 (execution of refund) + 7324 (execution of updateDailySpent) + 672 to log the event + _gasUsed
        uint256 amount = 36616 + _gasUsed;
        if(_gasPrice > 0 && _signatures > 0 && amount <= _gasLimit) {
            if(_gasPrice > tx.gasprice) {
                amount = amount * tx.gasprice;
            }
            else {
                amount = amount * _gasPrice;
            }
            updateDailySpent(_wallet, uint128(getCurrentLimit(_wallet)), amount);
            _wallet.invoke(_relayer, amount, EMPTY_BYTES);
        }
    }

    // Overrides verifyRefund to add the refund in the daily limit.
    function verifyRefund(BaseWallet _wallet, uint _gasUsed, uint _gasPrice, uint _signatures) internal view returns (bool) {
        if(_gasPrice > 0 && _signatures > 0 && (
            address(_wallet).balance < _gasUsed * _gasPrice
            || isWithinDailyLimit(_wallet, getCurrentLimit(_wallet), _gasUsed * _gasPrice) == false
            || _wallet.authorised(address(_wallet)) == false
        ))
        {
            return false;
        }
        return true;
    }

    // Overrides to use the incremental nonce and save some gas
    function checkAndUpdateUniqueness(BaseWallet _wallet, uint256 _nonce, bytes32 _signHash) internal returns (bool) {
        return checkAndUpdateNonce(_wallet, _nonce);
    }

    function validateSignatures(
        BaseWallet _wallet,
        bytes memory _data,
        bytes32 _signHash,
        bytes memory _signatures
    )
        internal
        view
        returns (bool)
    {
        address signer = recoverSigner(_signHash, _signatures, 0);
        return isOwner(_wallet, signer); // "TT: signer must be owner"
    }

    function getRequiredSignatures(BaseWallet _wallet, bytes memory _data) internal view returns (uint256) {
        bytes4 methodId = functionPrefix(_data);
        if (methodId == EXECUTE_PENDING_PREFIX) {
            return 0;
        }
        return 1;
    }
}