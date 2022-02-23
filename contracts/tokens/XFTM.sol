// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract XFTM is ERC20Burnable {
    uint256 public constant GENESIS_SUPPLY = 5000 ether; // 5000 will be minted at genesis for liq pool seeding

    // CONTRACTS
    address public minter;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter() {
        require(minter == msg.sender, "Only minter can request");
        _;
    }

    /* ========== CONSTRUCTOR ========= */

    constructor() ERC20("BLAH Token", "BLAH") {
        _mint(_msgSender(), GENESIS_SUPPLY);
    }

    /* ========== MUTATIVE ========== */

    /// @notice Set minter for XFTM (only once)
    /// @param _minter Address of minting Pool
    function setMinter(address _minter) external {
        require(minter == address(0), "Fantasm::setMinter: NOT_ALLOWED");
        minter = _minter;
    }

    /// @notice Mint new XFTM token
    /// @param _address Address of receiver
    /// @param _amount Amount of new XFTM token
    function mint(address _address, uint256 _amount) external onlyMinter {
        _mint(_address, _amount);
    }

    /// @notice Burn XFTM token
    /// @param _from Address where token will be burnt from
    /// @param _amount Amount of XFTM token will be burnt
    function burn(address _from, uint256 _amount) external onlyMinter {
        _burn(_from, _amount);
    }
}
