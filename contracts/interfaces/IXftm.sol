// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IXftm is IERC20 {
    function burn(address _address, uint256 _amount) external;

    function burn(uint256 _amount) external;

    function mint(address _address, uint256 _amount) external;

    function setMinter(address _minter) external;
}
