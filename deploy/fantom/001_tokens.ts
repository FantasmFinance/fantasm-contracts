import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts}) => {
  const {deploy, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  await deploy('XFTM', {
    contract: 'XFTM',
    from: deployer,
    log: true,
    args: ['Fantastic Protocol XFTM Token', 'XFTM'],
  });

  const reserve = await deploy('FsmReserve', {
    from: deployer,
    log: true,
    args: [],
  });

  const treasuryFund = await deploy('FsmTreasuryFund', {
    from: deployer,
    log: true,
    args: [],
  });

  const daoFund = await deploy('FsmDaoFund', {
    from: deployer,
    log: true,
    args: [],
  });

  const devFund = await deploy('FsmDevFund', {
    from: deployer,
    log: true,
    args: [],
  });

  const fsm = await deploy('FSM', {
    contract: 'FSM',
    from: deployer,
    log: true,
    args: [
      'Fantastic Protocol FSM Token',
      'FSM',
      daoFund.address,
      devFund.address,
      treasuryFund.address,
      reserve.address
    ],
  });

  await execute('FsmReserve', {from: deployer, log: true }, 'initialize', fsm.address);
  await execute('FsmDaoFund', {from: deployer, log: true }, 'initialize', fsm.address);
  await execute('FsmTreasuryFund', {from: deployer, log: true }, 'initialize', fsm.address);
  await execute('FsmDevFund', {from: deployer, log: true }, 'initialize', fsm.address);
};

func.tags = ['tokens'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
