// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFantasm is IERC20 {
    function mint(address _address, uint256 _amount) external;

    function burn(uint256 _amount) external;

    function setRewarder(address _rewarder) external returns (bool);

    function setTreasuryFund(address _rewarder)
        external
        returns (
            uint256 _allocation,
            uint256 _vestingDuration,
            uint256 _vestingStart
        );

    function setDevFund(address _rewarder)
        external
        returns (
            uint256 _allocation,
            uint256 _vestingDuration,
            uint256 _vestingStart
        );

    function setPool(address _pool) external returns (bool);
}
