// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./libraries/boringcrypto/libraries/BoringMath.sol";
import "./libraries/boringcrypto/BoringBatchable.sol";
import "./libraries/boringcrypto/BoringOwnable.sol";
import "./libraries/Math.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarder.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IAngelFactory.sol";
import "./interfaces/IArchangel.sol";
import "./interfaces/IFountain.sol";
import "./utils/ErrorMsg.sol";

/// @notice Angel is a forked version of MiniChefV2 from SushiSwap with
/// minimal modifications to interact with fountain in Trevi. The staking
/// tokens are managed in fountain instead of here. Migrate related functions
/// withdrawAndHarvest are removed.
contract AngelBase is BoringOwnable, BoringBatchable, ErrorMsg {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of GRACE entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of GRACE to distribute per block.
    struct PoolInfo {
        uint128 accGracePerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;
    }

    /// @notice Address of GRACE contract.
    IERC20 public immutable GRACE;
    // @notice The migrator contract. It has a lot of power. Can only be set through governance (owner).

    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public gracePerSecond;
    uint256 private constant ACC_GRACE_PRECISION = 1e12;

    ////////////////////////// New
    IArchangel public immutable archangel;
    IAngelFactory public immutable factory;
    uint256 public endTime = 0;

    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event Withdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        IRewarder indexed rewarder
    );
    event LogSetPool(
        uint256 indexed pid,
        uint256 allocPoint,
        IRewarder indexed rewarder,
        bool overwrite
    );
    event LogUpdatePool(
        uint256 indexed pid,
        uint64 lastRewardTime,
        uint256 lpSupply,
        uint256 accGracePerShare
    );
    event LogGracePerSecond(uint256 gracePerSecond);

    modifier onlyFountain(uint256 pid) {
        _requireMsg(
            msg.sender == archangel.getFountain(address(lpToken[pid])),
            "General",
            "not called by correct fountain"
        );
        _;
    }

    /// @param _grace The GRACE token contract address.
    constructor(IERC20 _grace) public {
        GRACE = _grace;
        IAngelFactory _f = IAngelFactory(msg.sender);
        factory = _f;
        archangel = IArchangel(_f.archangel());
    }

    function getContractName() public pure override returns (string memory) {
        return "Angel";
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() external view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(
        uint256 allocPoint,
        IERC20 _lpToken,
        IRewarder _rewarder
    ) external onlyOwner {
        uint256 pid = lpToken.length;

        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(
            PoolInfo({
                allocPoint: allocPoint.to64(),
                lastRewardTime: block.timestamp.to64(),
                accGracePerShare: 0
            })
        );
        emit LogPoolAddition(pid, allocPoint, _lpToken, _rewarder);

        ////////////////////////// New
        // Update pid in fountain
        IFountain fountain =
            IFountain(archangel.getFountain(address(_lpToken)));
        fountain.setPoolId(pid);
    }

    /// @notice Update the given pool's GRACE allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        IRewarder _rewarder,
        bool overwrite
    ) external onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        if (overwrite) {
            rewarder[_pid] = _rewarder;
        }
        emit LogSetPool(
            _pid,
            _allocPoint,
            overwrite ? _rewarder : rewarder[_pid],
            overwrite
        );
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, endTime);
    }

    /// TODO: Add func description
    function setGraceReward(uint256 _amount, uint256 _endTime) external onlyOwner {
        require(block.timestamp > endTime, "last period not finish yet");
        // TODO: should check _amount?
        require(_amount > 0, "grace amount should be greater than 0");
        require(_endTime > block.timestamp, "end time should be in the future");
        // massUpdatePools
        uint256 len = lpToken.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(i);
        }
        uint256 duration = _endTime.sub(block.timestamp);
        // TODO: inject perSecond code and delete func?
        _setGracePerSecond(_amount/duration);
        endTime = _endTime;
        GRACE.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @notice Sets the grace per second to be distributed. Can only be called by the owner.
    /// @param _gracePerSecond The amount of Grace to be distributed per second.
    function _setGracePerSecond(uint256 _gracePerSecond) internal {
        gracePerSecond = _gracePerSecond;
        emit LogGracePerSecond(_gracePerSecond);
    }

    /// @notice View function to see pending GRACE on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending GRACE reward for a given user.
    function pendingGrace(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending)
    {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGracePerShare = pool.accGracePerShare;
        ////////////////////////// New
        // uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        // Need to get the lpSupply from fountain
        IFountain fountain =
            IFountain(archangel.getFountain(address(lpToken[_pid])));
        (, uint256 lpSupply) = fountain.angelInfo(address(this));
        if (lastTimeRewardApplicable() > pool.lastRewardTime && lpSupply != 0) {
            uint256 time = lastTimeRewardApplicable().sub(pool.lastRewardTime);
            uint256 graceReward =
                time.mul(gracePerSecond).mul(pool.allocPoint) / totalAllocPoint;
            accGracePerShare = accGracePerShare.add(
                graceReward.mul(ACC_GRACE_PRECISION) / lpSupply
            );
        }
        pending = int256(
            user.amount.mul(accGracePerShare) / ACC_GRACE_PRECISION
        )
            .sub(user.rewardDebt)
            .toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.timestamp > pool.lastRewardTime) {
            ////////////////////////// New
            // uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            // Need to get the lpSupply from fountain
            IFountain fountain =
                IFountain(archangel.getFountain(address(lpToken[pid])));
            (, uint256 lpSupply) = fountain.angelInfo(address(this));
            // Only accumulate reward before end time
            if (lpSupply > 0 && lastTimeRewardApplicable() > pool.lastRewardTime) {
                uint256 time = lastTimeRewardApplicable().sub(pool.lastRewardTime);
                uint256 graceReward =
                    time.mul(gracePerSecond).mul(pool.allocPoint) /
                        totalAllocPoint;
                pool.accGracePerShare = pool.accGracePerShare.add(
                    (graceReward.mul(ACC_GRACE_PRECISION) / lpSupply).to128()
                );
            }
            pool.lastRewardTime = block.timestamp.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(
                pid,
                pool.lastRewardTime,
                lpSupply,
                pool.accGracePerShare
            );
        }
    }

    /// @notice Deposit LP tokens to MCV2 for GRACE allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(
        uint256 pid,
        uint256 amount,
        address to
    ) external onlyFountain(pid) {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(
            int256(amount.mul(pool.accGracePerShare) / ACC_GRACE_PRECISION)
        );

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGraceReward(pid, to, to, 0, user.amount);
        }

        ////////////////////////// New
        // Handle in fountain
        // lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        // emit Deposit(msg.sender, pid, amount, to);
        emit Deposit(to, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(
        uint256 pid,
        uint256 amount,
        address to
    ) external onlyFountain(pid) {
        PoolInfo memory pool = updatePool(pid);
        ////////////////////////// New
        // Delegate by fountain
        // UserInfo storage user = userInfo[pid][msg.sender];
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(
            int256(amount.mul(pool.accGracePerShare) / ACC_GRACE_PRECISION)
        );
        user.amount = user.amount.sub(amount);

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            ////////////////////////// New
            // Delegate by fountain
            // _rewarder.onGraceReward(pid, msg.sender, to, 0, user.amount);
            _rewarder.onGraceReward(pid, to, to, 0, user.amount);
        }

        ////////////////////////// New
        // Handle in fountain
        // lpToken[pid].safeTransfer(to, amount);

        // emit Withdraw(msg.sender, pid, amount, to);
        emit Withdraw(to, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of GRACE rewards.
    function harvest(
        uint256 pid,
        address from,
        address to
    ) external onlyFountain(pid) {
        PoolInfo memory pool = updatePool(pid);
        ////////////////////////// New
        // Delegate by fountain
        // UserInfo storage user = userInfo[pid][msg.sender];
        UserInfo storage user = userInfo[pid][from];
        int256 accumulatedGrace =
            int256(
                user.amount.mul(pool.accGracePerShare) / ACC_GRACE_PRECISION
            );
        uint256 _pendingGrace =
            accumulatedGrace.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedGrace;

        // Interactions
        if (_pendingGrace != 0) {
            GRACE.safeTransfer(to, _pendingGrace);
        }

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGraceReward(
                pid,
                ////////////////////////// New
                // Delegate by fountain
                // msg.sender,
                to,
                to,
                _pendingGrace,
                user.amount
            );
        }

        ////////////////////////// New
        // emit Harvest(msg.sender, pid, _pendingGrace);
        emit Harvest(from, pid, _pendingGrace);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to)
        external
        onlyFountain(pid)
    {
        ////////////////////////// New
        // Delegate by fountain
        // UserInfo storage user = userInfo[pid][msg.sender];
        UserInfo storage user = userInfo[pid][to];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            ////////////////////////// New
            // Delegate by fountain
            // _rewarder.onGraceReward(pid, msg.sender, to, 0, 0);
            // Execution of emergencyWithdraw should never fail. Considering
            // the possibility of failure caused by rewarder execution, use
            // try/catch on rewarder execution with limited gas
            try
                _rewarder.onGraceReward{gas: 1000000}(pid, to, to, 0, 0)
            {} catch {
                return;
            }
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        ////////////////////////// New
        // Handle in fountain
        // lpToken[pid].safeTransfer(to, amount);
        // emit EmergencyWithdraw(msg.sender, pid, amount, to);
        emit EmergencyWithdraw(to, pid, amount, to);
    }

    /// @notice Fetch the token from angel. Can only be called by owner.
    /// Cannot rescue the reward token.
    /// @param token The token address.
    /// @param to The receiver.
    /// @return The transferred amount.
    function rescueERC20(IERC20 token, address to)
        external
        onlyOwner
        returns (uint256)
    {
        _requireMsg(
            token != GRACE,
            "rescueERC20",
            "cannot rescue reward token"
        );
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);

        return amount;
    }
}
