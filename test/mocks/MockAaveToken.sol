// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { MockToken } from "test/mocks/MockToken.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { IERC20, IERC20Errors } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

contract MockAaveToken is IERC20, IERC20Errors {
    using SafeERC20 for MockToken;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    MockToken public immutable underlying;

    uint256 public immutable totalSupply = 0;
    uint256 public immutable apy;
    address public POOL;

    mapping(address => uint256) public _balanceOf;
    mapping(address => uint256) public _fixedAt;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(MockToken _underlying, uint256 _apy) {
        underlying = _underlying;
        apy = _apy;
    }

    function setPool(address pool) external {
        if (POOL != address(0)) revert();
        POOL = pool;
    }

    function mint(uint256 amount) external {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.burn(amount);
        _updateBalance(msg.sender, amount.toInt256());
    }

    function burn(uint256 amount) external {
        underlying.mint(amount);
        underlying.safeTransfer(msg.sender, amount);
        _updateBalance(msg.sender, -amount.toInt256());
    }

    function burn(address account, uint256 amount) external {
        underlying.mint(amount);
        underlying.safeTransfer(msg.sender, amount);
        _updateBalance(account, -amount.toInt256());
    }

    function rebase(address account, int256 delta) external {
        _updateBalance(account, delta);
    }

    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return address(underlying);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balanceOf[account] + _yieldOf(account);
    }

    function _yieldOf(address account) public view returns (uint256) {
        (bool initialized, uint256 fixedAt) = _getFixedAt(account);

        if (!initialized || _balanceOf[account] == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - fixedAt;
        return _balanceOf[account].mulDiv(elapsed * apy, 365 days * 100);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _updateBalance(msg.sender, -amount.toInt256());
        _updateBalance(to, amount.toInt256());
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, ERC20InsufficientAllowance(to, currentAllowance, amount));
        allowance[from][msg.sender] = currentAllowance - amount;

        _updateBalance(from, -amount.toInt256());
        _updateBalance(to, amount.toInt256());
        emit Transfer(from, to, amount);
        return true;
    }

    function _updateBalance(address account, int256 delta) internal {
        uint256 newBalance = balanceOf(account);
        _saveFixedAt(account);

        if (delta < 0 && newBalance < (-delta).toUint256()) {
            revert ERC20InsufficientBalance(account, newBalance, (-delta).toUint256());
        }

        if (delta < 0) {
            newBalance -= (-delta).toUint256();
        } else {
            newBalance += delta.toUint256();
        }

        _balanceOf[account] = newBalance;
    }

    function _saveFixedAt(address account) internal {
        _fixedAt[account] = block.timestamp + 1;
    }

    function _getFixedAt(address account) internal view returns (bool initialized, uint256 fixedAt) {
        if (_fixedAt[account] == 0) {
            return (false, 0);
        }

        return (true, _fixedAt[account] - 1);
    }
}

contract TestMockAaveToken is Test {
    MockToken underlying;
    MockAaveToken aaveToken;

    uint256 constant YEAR = 365 days;

    function setUp() public {
        vm.warp(0);

        underlying = new MockToken();
        aaveToken = new MockAaveToken(underlying, 10);
    }

    function test_cant_mint_without_underlying() public {
        vm.expectRevert();
        aaveToken.mint(1000);
    }

    function test_yielding() public {
        _mint(1000);

        assertEq(aaveToken.balanceOf(address(this)), 1000);

        skip(YEAR);
        assertEq(aaveToken.balanceOf(address(this)), 1000 + 100);

        aaveToken.burn(600);
        assertEq(underlying.balanceOf(address(this)), 600);
        assertEq(aaveToken.balanceOf(address(this)), 500);

        skip(YEAR);
        assertEq(aaveToken.balanceOf(address(this)), 550);
        aaveToken.burn(550);
    }

    function test_no_yield_when_balance_zero() public {
        _mint(1000);

        skip(YEAR);
        aaveToken.burn(1100);
        assertEq(aaveToken.balanceOf(address(this)), 0);

        skip(YEAR);
        assertEq(aaveToken.balanceOf(address(this)), 0);
    }

    function test_double_minting() public {
        _mint(1000);

        skip(YEAR);
        assertEq(aaveToken.balanceOf(address(this)), 1100);

        _mint(1000);
        skip(YEAR);
        assertEq(aaveToken.balanceOf(address(this)), 2310);
    }

    function test_sum_of_balances() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        _mint(user1, 1000);
        _mint(user2, 1000);
        _mint(user3, 2000);

        skip(YEAR * 10);
        assertEq(
            aaveToken.balanceOf(user1) + aaveToken.balanceOf(user2),
            aaveToken.balanceOf(user3)
        );
    }

    function _mint(address user, uint256 amount) internal {
        vm.prank(user); underlying.mint(amount);
        vm.prank(user); underlying.approve(address(aaveToken), amount);
        vm.prank(user); aaveToken.mint(amount);
    }

    function _mint(uint256 amount) internal {
        _mint(address(this), amount);
    }
}
