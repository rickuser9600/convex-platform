// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./Interfaces.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';


contract ExtraRewardStashV2 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    uint256 private constant maxRewards = 8;
    uint256 private constant WEEK = 7 * 86400;

    uint256 public pid;
    address public operator;
    address public staker;
    address public gauge;
    address public rewardFactory;
   
    mapping(address => uint256) public historicalRewards;

    struct TokenInfo {
        address token;
        address rewardAddress;
        uint256 lastActiveTime;
    }
    TokenInfo[] public tokenInfo;

    constructor(uint256 _pid, address _operator, address _staker, address _gauge, address _rFactory) public {
        pid = _pid;
        operator = _operator;
        staker = _staker;
        gauge = _gauge;
        rewardFactory = _rFactory;
    }

    function getName() external pure returns (string memory) {
        return "ExtraRewardStashV2";
    }

    //v2 gauges can have multiple incentive tokens
    function tokenCount() public view returns (uint256) {
        uint256 length = tokenInfo.length;
        if(length > 0 && tokenInfo[0].token != address(0)){
            return length;
        }
        return 0;
    }

    //try claiming if there are reward tokens registered
    function claimRewards() external returns (bool) {
        require(msg.sender == operator, "!authorized");

        //this is updateable in v2 gauges now so must check each time.
        checkForNewRewardTokens();


        uint256 count = tokenCount();
        if(count > 0){
            //get previous balances of all tokens
            uint256[] memory balances = new uint256[](count);
            for(uint256 i=0; i < tokenInfo.length; i++){
                 address token = tokenInfo[i].token;
                if(token == address(0)) continue;

                balances[i] = IERC20(tokenInfo[i].token).balanceOf(staker);
            }
            //claim rewards on gauge for staker
            //lets have booster call for future proofing (cant assume anyone will always be able to call)
            //ICurveGauge(gauge).claim_rewards(staker);
            IDeposit(operator).claimRewards(pid,gauge);

            for(uint256 i=0; i < tokenInfo.length; i++){
                address token = tokenInfo[i].token;
                if(token == address(0)) continue;

                uint256 newbalance = IERC20(tokenInfo[i].token).balanceOf(staker);
                //stash if balance increased
                if(newbalance > balances[i]){
                    IStaker(staker).withdraw(token);
                    tokenInfo[i].lastActiveTime = block.timestamp;

                    //make sure this pool is in active list,
                    IRewardFactory(rewardFactory).addActiveReward(token,pid);


                    //check if other stashes are also active, and if so, send to arbitrator
                    //do this here because processStash will have tokens from the arbitrator
                    uint256 activeCount = IRewardFactory(rewardFactory).activeRewardCount(token);
                    if(activeCount > 1){
                        //send to arbitrator
                        address arb = IDeposit(operator).rewardArbitrator();
                        if(arb != address(0)){
                            IERC20(token).safeTransfer(arb, newbalance);
                        }
                    }

                }else{
                    //check if this reward has been inactive too long
                    if(block.timestamp > tokenInfo[i].lastActiveTime + WEEK){
                        //set as inactive
                        IRewardFactory(rewardFactory).removeActiveReward(token,pid);
                    }else{
                        //edge case around reward ending periods
                        if(newbalance > 0){
                            // - recently active pool
                            // - rewards claimed to staker contract via a deposit/withdraw(or someone manually calling on the gauge)
                            // - rewards ended before the deposit, thus deposit took the last available tokens
                            // - thus claimRewards doesnt see any new rewards, but there are rewards on the staker contract
                            // - i think its safe to assume claim will be called within the timeframe, or else these rewards
                            //     will be unretrievable until some pool starts rewards again 

                            //claim the tokens
                            IStaker(staker).withdraw(token);

                            uint256 activeCount = IRewardFactory(rewardFactory).activeRewardCount(token);
                            if(activeCount > 1){
                                //send to arbitrator
                                address arb = IDeposit(operator).rewardArbitrator();
                                if(arb != address(0)){
                                    IERC20(token).safeTransfer(arb, newbalance);
                                }
                            }
                        }
                    }
                }
            }
        }
        return true;
    }
   

    //check if gauge rewards have changed
    function checkForNewRewardTokens() internal {
        uint256 length = tokenInfo.length;
        for(uint256 i = 0; i < maxRewards; i++){
            address token = ICurveGauge(gauge).reward_tokens(i);
            if (token == address(0)) {
                for (uint x = i; x < length; x++) {
                    tokenInfo.pop();
                }
                break;
            }

            //replace or grow list
            if(i < length){
                setToken(i,token);
            }else{
                addToken(token);   
            }
        }
    }

    //add a new token to token list
    function addToken(address _token) internal {
        //get address of main rewards of pool
         (,,,address mainRewardContract,,) = IDeposit(operator).poolInfo(pid);

         //create a new reward contract for this extra reward token
        address rewardContract = IRewardFactory(rewardFactory).CreateTokenRewards(
        	_token,
        	mainRewardContract,
        	address(this));

        //add to token list
        tokenInfo.push(
            TokenInfo({
                token: _token,
                rewardAddress: rewardContract,
                lastActiveTime: 0 //do not set as active yet, wait for first earmark
            })
        );
    }

    //replace a token on token list
    function setToken(uint256 _tid, address _token) internal {
        if(tokenInfo[_tid].token != _token){
            //set old as inactive
            IRewardFactory(rewardFactory).removeActiveReward(tokenInfo[_tid].token,pid);

            //set token address
            tokenInfo[_tid].token = _token;

            if(_token == address(0)){
                //nullify reward address
            	tokenInfo[_tid].rewardAddress = address(0);
                tokenInfo[_tid].lastActiveTime = 0;
            }else{
	            //create new reward contract
	             (,,,address mainRewardContract,,) = IDeposit(operator).poolInfo(pid);
	        	address rewardContract = IRewardFactory(rewardFactory).CreateTokenRewards(
		        	_token,
		        	mainRewardContract,
		        	address(this));
	            tokenInfo[_tid].rewardAddress = rewardContract;
                tokenInfo[_tid].lastActiveTime = 0;
                //do not set as active yet, wait for first earmark
        	}
        }
    }

    //pull assigned tokens from staker to stash
    function stashRewards() external returns(bool){
        require(msg.sender == operator, "!authorized");

        //after depositing/withdrawing, extra incentive tokens are transfered to the staking contract
        //need to pull them off and stash here.
        for(uint i=0; i < tokenInfo.length; i++){
            address token = tokenInfo[i].token;
            if(token == address(0)) continue;
            
            //only stash if rewards are active
            if(block.timestamp <= tokenInfo[i].lastActiveTime + WEEK){
                uint256 before = IERC20(token).balanceOf(address(this));
                IStaker(staker).withdraw(token);
               

                //check for multiple pools claiming same token
                uint256 activeCount = IRewardFactory(rewardFactory).activeRewardCount(token);
                if(activeCount > 1){
                    //take difference of before/after(only send new tokens)
                    uint256 amount = IERC20(token).balanceOf(address(this));
                    amount = amount.sub(before);

                    //send to arbitrator
                    address arb = IDeposit(operator).rewardArbitrator();
                    if(arb != address(0)){
                        IERC20(token).safeTransfer(arb, amount);
                    }
                }
            }
        }
        return true;
    }

    //send all extra rewards to their reward contracts
    function processStash() external returns(bool){
        require(msg.sender == operator, "!authorized");

        for(uint i=0; i < tokenInfo.length; i++){
            address token = tokenInfo[i].token;
            if(token == address(0)) continue;
            
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount > 0) {
                historicalRewards[token] = historicalRewards[token].add(amount);
                if(token == crv){
                    //if crv, send back to booster to distribute
                    IERC20(token).safeTransfer(operator, amount);
                    continue;
                }
            	//add to reward contract
            	address rewards = tokenInfo[i].rewardAddress;
            	if(rewards == address(0)) continue;
            	IERC20(token).safeTransfer(rewards, amount);
            	IRewards(rewards).queueNewRewards(amount);
            }
        }
        return true;
    }

}