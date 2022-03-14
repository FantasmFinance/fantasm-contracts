import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  await deploy('XFTM', {
    contract: 'XFTM',
    from: deployer,
    log: true,
    args: ['Fantastic Protocol XFTM Token', 'XFTM'],
  });

  const fsm = await deploy('FSM', {
    contract: 'FSM',
    from: deployer,
    log: true,
    args: ['Fantastic Protocol FSM Token', 'FSM'],
  });

  const reserve = await deploy('FsmReserve', {
    from: deployer,
    log: true,
    args: [fsm.address],
  });

  await deploy('FsmTreasuryFund', {
    from: deployer,
    log: true,
    args: [fsm.address],
  });

  await deploy('FsmDaoFund', {
    from: deployer,
    log: true,
    args: [fsm.address],
  });
};

func.tags = ['tokens'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
