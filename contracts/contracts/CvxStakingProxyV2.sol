// SPDX-License-Identifier: MIT
pragma solidity 0.6 .12;

import "./interfaces/ICrvDepositor.sol";
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';



interface IConvexRewards {
    function withdraw(uint256 _amount, bool _claim) external;

    function balanceOf(address _account) external view returns(uint256);

    function getReward(bool _stake) external;

    function stakeAll() external;
}

interface ICvxLocker {
    function notifyRewardAmount(address _rewardsToken, uint256 reward) external;
}


// receive tokens to stake
// get current staked balance
// withdraw staked tokens
// send rewards back to owner(cvx locker)
// register token types that can be distributed

contract CvxStakingProxyV2 {
    using SafeERC20
    for IERC20;
    using Address
    for address;
    using SafeMath
    for uint256;

    //tokens
    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    address public constant cvxCrv = address(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    //convex addresses
    address public constant cvxStaking = address(0xCF50b810E57Ac33B91dCF525C6ddd9881B139332);
    address public constant cvxCrvStaking = address(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    address public constant crvDeposit = address(0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae);
    uint256 public constant denominator = 10000;

    address public immutable rewards;

    address public owner;
    address public pendingOwner;
    uint256 public callIncentive = 100;

    mapping(address => bool) public distributors;
    bool public UseDistributors = true;

    event AddDistributor(address indexed _distro, bool _valid);
    event RewardsDistributed(address indexed token, uint256 amount);

    constructor(address _rewards) public {
        rewards = _rewards;
        owner = msg.sender;
        distributors[msg.sender] = true;
    }

    function setPendingOwner(address _po) external {
        require(msg.sender == owner, "!auth");
        pendingOwner = _po;
    }

    function applyPendingOwner() external {
        require(msg.sender == owner, "!auth");
        require(pendingOwner != address(0), "invalid owner");

        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setCallIncentive(uint256 _incentive) external {
        require(msg.sender == owner, "!auth");
        require(_incentive <= 100, "too high");
        callIncentive = _incentive;
    }

    function setDistributor(address _distro, bool _valid) external {
        require(msg.sender == owner, "!auth");
        distributors[_distro] = _valid;
        emit AddDistributor(_distro, _valid);
    }

    function setUseDistributorList(bool _use) external {
        require(msg.sender == owner, "!auth");
        UseDistributors = _use;
    }

    function setApprovals() external {
        IERC20(cvx).safeApprove(cvxStaking, 0);
        IERC20(cvx).safeApprove(cvxStaking, uint256(-1));

        IERC20(crv).safeApprove(crvDeposit, 0);
        IERC20(crv).safeApprove(crvDeposit, uint256(-1));

        IERC20(cvxCrv).safeApprove(rewards, 0);
        IERC20(cvxCrv).safeApprove(rewards, uint256(-1));
    }

    function rescueToken(address _token, address _to) external {
        require(msg.sender == owner, "!auth");
        require(_token != crv && _token != cvx && _token != cvxCrv, "not allowed");

        uint256 bal = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(_to, bal);
    }

    function getBalance() external view returns(uint256) {
        return IConvexRewards(cvxStaking).balanceOf(address(this));
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == rewards, "!auth");

        //unstake
        IConvexRewards(cvxStaking).withdraw(_amount, false);

        //withdraw cvx
        IERC20(cvx).safeTransfer(msg.sender, _amount);
    }


    function stake() external {
        require(msg.sender == rewards, "!auth");

        IConvexRewards(cvxStaking).stakeAll();
    }

    function distribute() external {
        if(UseDistributors){
            require(distributors[msg.sender], "!auth");
        }

        //claim rewards
        IConvexRewards(cvxStaking).getReward(false);

        //convert any crv that was directly added
        uint256 crvBal = IERC20(crv).balanceOf(address(this));
        if (crvBal > 0) {
            ICrvDepositor(crvDeposit).deposit(crvBal, true);
        }

        //make sure nothing is in here
        uint256 sCheck  = IConvexRewards(cvxCrvStaking).balanceOf(address(this));
        if(sCheck > 0){
            IConvexRewards(cvxCrvStaking).withdraw(sCheck,false);
        }

        //distribute cvxcrv
        uint256 cvxCrvBal = IERC20(cvxCrv).balanceOf(address(this));

        if (cvxCrvBal > 0) {
            uint256 incentiveAmount = cvxCrvBal.mul(callIncentive).div(denominator);
            cvxCrvBal = cvxCrvBal.sub(incentiveAmount);
            
            //send incentives
            IERC20(cvxCrv).safeTransfer(msg.sender,incentiveAmount);

            //update rewards
            ICvxLocker(rewards).notifyRewardAmount(cvxCrv, cvxCrvBal);

            emit RewardsDistributed(cvxCrv, cvxCrvBal);
        }
    }

    //in case a new reward is ever added, allow generic distribution
    function distributeOther(IERC20 _token) external {
        require( address(_token) != crv && address(_token) != cvxCrv, "not allowed");

        uint256 bal = _token.balanceOf(address(this));

        if (bal > 0) {
            uint256 incentiveAmount = bal.mul(callIncentive).div(denominator);
            bal = bal.sub(incentiveAmount);
            
            //send incentives
            _token.safeTransfer(msg.sender,incentiveAmount);

            //approve
            _token.safeApprove(rewards, 0);
            _token.safeApprove(rewards, uint256(-1));

            //update rewards
            ICvxLocker(rewards).notifyRewardAmount(address(_token), bal);

            emit RewardsDistributed(address(_token), bal);
        }
    }
}