import {network} from 'hardhat';
import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts, wellknown}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  console.log('> deployer', deployer);
  console.log('> Network name:' + network.name);
  console.log('> wellknow:' + JSON.stringify(wellknown));
  console.log((wellknown as any)[network.name].addresses);

  const weth = {address: (wellknown as any)[network.name].addresses.weth};
  const swapRouter = {address: (wellknown as any)[network.name].addresses.swapRouter};
  const lp_fsm_eth = {address: (wellknown as any)[network.name].addresses.yTokenEth};

  const fsm = await get('FSM');
  const treasury = await get('FantasticTreasury');
  const wethUtils = await get('WethUtils');

  const swapSlippage = 20000; // 2%
  const swapPaths = [weth.address, fsm.address];
  const swapStrat = await deploy('SwapStrategyPOL', {
    from: deployer,
    log: true,
    args: [
      fsm.address,
      lp_fsm_eth.address,
      treasury.address,
      swapRouter.address,
      swapSlippage,
      swapPaths,
    ],
    libraries: {
      WethUtils: wethUtils.address,
    },
  });

  await execute('Pool', {from: deployer, log: true}, 'setSwapStrategy', swapStrat.address);
  await execute('Pool', {from: deployer, log: true}, 'setTreasury', treasury.address);
};

func.tags = ['swap_strat'];

func.skip = async ({network}) => {
  return network.name !== 'avax';
};

export default func;
