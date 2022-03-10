import {network} from 'hardhat';
import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts, wellknown}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  console.log('> deployer', deployer);
  console.log('> Network name:' + network.name);
  console.log('> wellknow:' + JSON.stringify(wellknown));
  console.log((wellknown as any)[network.name].addresses);

  const lp_xftm_eth = {address: (wellknown as any)[network.name].addresses.xTokenEth};
  const lp_fsm_eth = {address: (wellknown as any)[network.name].addresses.yTokenEth};

  const pairFsmEth = await deploy('PairOracle_FSM_ETH', {
    contract: 'UniswapPairOracle',
    from: deployer,
    log: true,
    args: [lp_fsm_eth.address],
  });

  const pairXftmEth = await deploy('PairOracle_XFTM_ETH', {
    contract: 'UniswapPairOracle',
    from: deployer,
    log: true,
    args: [lp_xftm_eth.address],
  });

  await execute('PairOracle_FSM_ETH', {from: deployer, log: true}, 'setPeriod', 1);
  await execute('PairOracle_XFTM_ETH', {from: deployer, log: true}, 'setPeriod', 1);

  await execute('PairOracle_FSM_ETH', {from: deployer, log: true}, 'update');
  await execute('PairOracle_XFTM_ETH', {from: deployer, log: true}, 'update');

  await execute('PairOracle_FSM_ETH', {from: deployer, log: true}, 'setPeriod', 3600);
  await execute('PairOracle_XFTM_ETH', {from: deployer, log: true}, 'setPeriod', 3600);

  const xftm = await get('XFTM');
  const fsm = await get('FSM');

  await deploy('MasterOracle', {
    from: deployer,
    log: true,
    args: [xftm.address, fsm.address, pairXftmEth.address, pairFsmEth.address],
  });
};

func.tags = ['oracles'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
