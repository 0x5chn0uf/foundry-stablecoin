// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_COVER = 20 ether;
    uint256 public constant AMOUNT_DSC_MINTED = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amountCollateral
    );

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDSC() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_MINTED);
        vm.stopPrank();
        _;
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAdressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testRevertIfAddressMintAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    function testGetUsdValue() public view {
        uint256 amount = 15e18;
        uint256 expectedUsd = 30000e18;

        uint256 actualUsd = engine.getUsdValue(weth, amount);
        assertEq(actualUsd, expectedUsd);
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        engine.mintDsc(AMOUNT_DSC_MINTED);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_DSC_MINTED);
    }

    function testRevertIfBurnAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.burnDSC(0);
    }

    function testCantBurnMoreThanUserHave() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDSC(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);
        engine.burnDSC(AMOUNT_DSC_MINTED);
        vm.stopPrank();

        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(totalDscMinted, 0);
        assertEq(userBalance, 0);
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(totalDscMinted, 0);
        assertEq(userBalance, 0);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndMintDSC() public depositedCollateralAndMintedDSC {
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(totalDscMinted, AMOUNT_DSC_MINTED);
        assertEq(userBalance, AMOUNT_DSC_MINTED);
    }

    function testRevertMintBecauseBreaksHealthScore() public depositedCollateral {
        (, int256 ethPrice,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountDscMinted =
            AMOUNT_COLLATERAL * uint256(ethPrice) * engine.getAdditionnalFeedPrecision() / engine.getPrecision();

        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 collateralAdjustedForTreshold = (collateralValueInUsd * 50) / 100;
        uint256 expectedHealthFactor = (collateralAdjustedForTreshold * engine.getPrecision() / amountDscMinted);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountDscMinted);
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.prank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        uint256 expectedCollateralValueInUsd = 0;
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(userBalance, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);

        vm.prank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    function testRevertIsRedeemAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralForDSC() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);
        engine.redeemCollateralForDSC(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_MINTED);
        vm.stopPrank();

        uint256 userBalanceOfDSC = dsc.balanceOf(USER);
        uint256 userBalanceOfWeth = ERC20Mock(weth).balanceOf(USER);

        assertEq(userBalanceOfDSC, 0);
        assertEq(userBalanceOfWeth, AMOUNT_COLLATERAL);
    }

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDSC {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.redeemCollateralForDSC(weth, 0, AMOUNT_DSC_MINTED);
        vm.stopPrank();
    }

    function testHealthScoreIsCorrectlyComputed() public depositedCollateralAndMintedDSC {
        uint256 expectedHealthFactor = 100 ether;
        uint256 actualHealthFactor = engine.getHealthFactor(USER);

        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthScoreCanGoBelowOne() public depositedCollateralAndMintedDSC {
        int256 ethUsdPriceUpdated = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdPriceUpdated);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor == 0.9 ether);
    }

    modifier liquidation() {
        uint256 startingHealthFactor = engine.getHealthFactor(USER);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        console.log("Starting HealthFactor: ", startingHealthFactor / engine.getPrecision());
        console.log("Total DSC Minted: ", totalDscMinted / engine.getPrecision());
        console.log("Collateral Value in USD: ", collateralValueInUsd / engine.getPrecision());
        console.log("Collateral Balance: ", engine.getCollateralBalanceOfUser(USER, weth) / engine.getPrecision());

        int256 ethUsdPriceUpdated = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdPriceUpdated);

        ERC20Mock(weth).mint(LIQUIDATOR, AMOUNT_COLLATERAL_TO_COVER);

        uint256 tokenAmountFromDebt = engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_MINTED);
        uint256 bonusCollateral = (tokenAmountFromDebt * 10) / 100;
        uint256 totalCollateralToRedeem = tokenAmountFromDebt + bonusCollateral;

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL_TO_COVER, AMOUNT_DSC_MINTED);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);

        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, LIQUIDATOR, weth, totalCollateralToRedeem);
        engine.liquidate(weth, USER, AMOUNT_DSC_MINTED);

        vm.stopPrank();
        _;
    }

    function testUserStillHaveSomeEthAfterLiquidation() public depositedCollateralAndMintedDSC liquidation {
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_MINTED)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_MINTED) / engine.getLiquidationBonus());
        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - usdAmountLiquidated;

        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        assertEq(expectedUserCollateralValueInUsd, collateralValueInUsd);
    }

    function testLiquidationPayoutIsCorrect() public depositedCollateralAndMintedDSC liquidation {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWethBalance = engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_MINTED)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_MINTED) / engine.getLiquidationBonus());

        // 6_111_111_111_111_111_110
        assertEq(expectedWethBalance, liquidatorWethBalance);
    }

    function testCantLiquidateIfHealthFactorOK() public depositedCollateralAndMintedDSC {
        ERC20Mock(weth).mint(LIQUIDATOR, AMOUNT_COLLATERAL_TO_COVER);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL_TO_COVER, AMOUNT_DSC_MINTED);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        engine.liquidate(weth, USER, AMOUNT_DSC_MINTED);

        vm.stopPrank();
    }

    function testNoMoreDebt() public depositedCollateralAndMintedDSC liquidation {
        uint256 endingUserHealthFactor = engine.getHealthFactor(USER);

        int256 ethUsdPriceUpdated = 1000e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdPriceUpdated);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        console.log("Ending HealthFactor: ", endingUserHealthFactor / engine.getPrecision());
        console.log("Total DSC Minted: ", totalDscMinted / engine.getPrecision());
        console.log("Collateral Value in USD: ", collateralValueInUsd);
        console.log("Collateral Balance: ", engine.getCollateralBalanceOfUser(USER, weth));

        assertEq(endingUserHealthFactor, type(uint256).max);
        assertEq(totalDscMinted, 0);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 accountCollateralValue = engine.getAccountCollateralValue(USER);
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 expectedAccountCollateralValue =
            AMOUNT_COLLATERAL * uint256(price) * engine.getAdditionnalFeedPrecision() / engine.getPrecision();

        assertEq(expectedAccountCollateralValue, accountCollateralValue);
    }

    function testGetLiquidationBonus() public view {
        uint256 liquidationBonus = engine.getLiquidationBonus();
        assertEq(liquidationBonus, 10);
    }
}
