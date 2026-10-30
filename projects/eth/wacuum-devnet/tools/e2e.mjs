// A wallet library against a running devnet: fund a fresh wallet through the faucet form, deploy a
// contract, call it, send ether, and check the explorer shows it. Needs ethers 6 where node can find it:
//
//     npm install --no-save ethers@6 && node tools/e2e.mjs [http://127.0.0.1:8545]

import { ethers } from "ethers";
const url = process.argv[2] ?? "http://127.0.0.1:8545";
const p = new ethers.JsonRpcProvider(url + "/rpc");
const w = ethers.Wallet.createRandom().connect(p);
// Fund the fresh wallet through the faucet form, as a visitor would.
let r = await fetch(url + "/faucet", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "x-forwarded-for": "203.0.113." + Math.floor(Math.random()*250) },
  body: "address=" + w.address });
console.log("faucet", r.status);
while ((await p.getBalance(w.address)) === 0n) await new Promise(r => setTimeout(r, 500));
console.log("balance", ethers.formatEther(await p.getBalance(w.address)));
// Deploy a contract that returns 42, then call it.
const initcode = "0x600a600c600039600a6000f3602a60005260206000f3";
const tx = await w.sendTransaction({ data: initcode });
const rc = await tx.wait();
console.log("deployed", rc.contractAddress, "status", rc.status);
console.log("call", await p.call({ to: rc.contractAddress }));
const t2 = await w.sendTransaction({ to: "0x00000000000000000000000000000000000dead1", value: ethers.parseEther("1") });
console.log("transfer", (await t2.wait()).status);
const page = await (await fetch(url + "/address/" + rc.contractAddress.toLowerCase())).text();
console.log("contract page says Contract:", page.includes("<h1>Contract</h1>"));
const wpage = await (await fetch(url + "/address/" + w.address)).text();
console.log("wallet page lists create:", wpage.includes(">create<"));
