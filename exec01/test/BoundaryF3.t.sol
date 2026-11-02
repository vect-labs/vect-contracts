// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockWorld} from "./MockWorld.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev E4 QA finding F-3: boundary tests that kill the recipient min-out off-by-one (QM4), the fee taken on the
/// declared amount instead of the received one (QM12) and an inflating input token (QM11).
contract BoundaryF3Test is MockWorld {
    /// QM4: with a token taxing the executor's payout, min-out equal to the user's exact receipt passes, one wei more reverts.
    function test_recipient_min_out_exact_boundary_on_a_taxed_output() public {
        MockERC20 tax = new MockERC20("TAX");
        _v3Pool(A, tax, 3000);
        _give(A, 1_000 ether);
        tax.setTax(1000);
        tax.setTaxFrom(address(exec));
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(tax), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 got = _runErc20(r, address(A), 10 ether, address(tax), 1, 0, false);
        assertEq(tax.balanceOf(user), got);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        assertEq(_runErc20(r, address(A), 10 ether, address(tax), got, 0, false), got);
        vm.revertToState(snap);
        Args memory a = _args(r, address(A), 10 ether, address(tax), got + 1, 0, false);
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
    }

    /// QM12: on a taxed input (single v2 leg), the input fee is taken on what the executor received, not on amountIn.
    function test_input_fee_base_is_the_received_amount_on_a_taxed_input() public {
        MockERC20 tax = new MockERC20("TAX");
        _v2Pair(tax, B);
        tax.setTax(1000); // 10 % burned on every transfer, including the fee transfer
        _give(tax, 1_000 ether);
        uint256 amt = 100 ether;
        uint16 feeBps = 100; // 1 %
        uint256 before = tax.balanceOf(FEE_RECIPIENT);
        _runErc20(_route1(_leg1(amt, _v2(address(tax), address(B)))), address(tax), amt, address(B), 1, feeBps, false);
        uint256 received = amt - (amt * 1000) / 10_000; // what the executor got from the user
        uint256 fee = (received * feeBps) / 10_000; // the fee on the received amount
        uint256 feeArrived = fee - (fee * 1000) / 10_000; // the fee transfer is taxed too
        assertEq(tax.balanceOf(FEE_RECIPIENT) - before, feeArrived);
        assertEq(tax.balanceOf(address(exec)), 0);
    }

    /// QM11: an input token that credits the executor more than amountIn is refused.
    function test_inflating_input_token_is_refused() public {
        MockERC20 infl = new MockERC20("INFL");
        _v2Pair(infl, B);
        _give(infl, 1_000 ether);
        infl.setBonus(100); // the recipient gets 1 % more than sent
        Args memory a = _args(_route1(_leg1(10 ether, _v2(address(infl), address(B)))), address(infl), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadReceived.selector);
        _go(a);
    }
}
