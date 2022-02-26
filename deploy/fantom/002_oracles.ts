import {DeployFunction} from 'hardhat-deploy/dist/types';

const Addresses = {
  lp_xftm_eth: '0x128aff18EfF64dA69412ea8d262DC4ef8bb3102d',
  lp_fsm_eth: '0x457C8Efcd523058dd58CF080533B41026788eCee',
};
const func: DeployFunction = async ({deployments, getNamedAccounts}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  const pairFsmEth = await deploy('PairOracle_FSM_ETH', {
    contract: 'UniswapPairOracle',
    from: deployer,
    log: true,
    args: [Addresses.lp_fsm_eth],
  });

  // await execute('PairOracle_FSM_ETH', {from: deployer, log: true}, 'setPeriod', 600);

  const pairXftmEth = await deploy('PairOracle_XFTM_ETH', {
    contract: 'UniswapPairOracle',
    from: deployer,
    log: true,
    args: [Addresses.lp_xftm_eth],
  });

  // await execute('PairOracle_XFTM_ETH', {from: deployer, log: true}, 'setPeriod', 600);

  const xftm = await get('XFTM');
  const fantasm = await get('Fantasm');

  const oracle = await deploy('MasterOracle', {
    from: deployer,
    log: true,
    args: [xftm.address, fantasm.address, pairXftmEth.address, pairFsmEth.address],
  });

  await execute('Pool', {from: deployer, log: true}, 'setOracle', oracle.address);
};

func.tags = ['oracles'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
