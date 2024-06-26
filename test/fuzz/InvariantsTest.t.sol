// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Handler} from "./Handler.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Invariants is StdInvariant, Test {
    DeployDsc deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();

        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(engine));
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        // console.log("Weth total deposited", totalWethDeposited);
        // console.log("Wbtc total deposited", totalWbtcDeposited);
        // console.log("Total supply of DSC", totalSupply);
        // console.log("WETH Value: %s", wethValue);
        // console.log("WBTC Value: %s", wbtcValue);

        // console.log("Statistiques");
        // console.log("mintAndDepositCollateral called:", handler.mintAndDepositCollateralNumberOfCall());
        // console.log("redeemCollateral called:", handler.redeemCollateralNumberOfCall());
        // console.log("mintDSC called:", handler.mintDSCNumberOfCall());
        // console.log("burnDSC called:", handler.burnDSCNumberOfCall());
        // console.log(
        //     "Total Call:",
        //     handler.burnDSCNumberOfCall() + handler.mintDSCNumberOfCall()
        //         + handler.mintAndDepositCollateralNumberOfCall() + handler.redeemCollateralNumberOfCall()
        // );

        // console.log("Users who minted DSC: ", handler.getUserWhoMintedDSCLength());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        engine.getAdditionnalFeedPrecision();
        engine.getCollateralTokens();
        engine.getLiquidationBonus();
        engine.getLiquidationTreshold();
        engine.getPrecision();
        engine.getLiquidationPrecision();
        engine.getMinHealthFactor();
    }
}
