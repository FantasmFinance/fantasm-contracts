export const wellknown = {
  fantom: {
    addresses: {
      weth: '0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83',
      xTokenEth: '0x55E784f2b127f6AbF5cD7C8ffCD1836889E8A885', // xftm/weth
      yTokenEth: '0x846d642859Fe7d613325AbFDB9eaaEC9474f6B69', // fsm/weth
      swapRouter: '0xF491e7B69E4244ad4002BC14e878a34207E38c29', // spooky
    },
  },
};

export type Wellknown = typeof wellknown;
