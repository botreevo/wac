// The one script the site runs: offering the chain to a browser wallet, and filling the faucet's form with
// the wallet's address. Everything else on these pages is HTML drawn by the node.
(function () {
  var add = document.getElementById("add-network");
  var status = document.getElementById("add-network-status");
  var mine = document.getElementById("use-wallet");
  var field = document.querySelector("form.faucet input[name=address]");
  function say(text) { if (status) status.textContent = " " + text; }
  if (!window.ethereum) {
    if (add) add.disabled = true;
    if (mine) mine.hidden = true;
    say("No browser wallet found: add the network by hand with the details above.");
    return;
  }
  if (add) add.addEventListener("click", function () {
    var d = add.dataset;
    window.ethereum.request({ method: "wallet_addEthereumChain", params: [{
      chainId: d.chainId, chainName: d.name, rpcUrls: [d.rpc], blockExplorerUrls: [d.explorer],
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }
    }] }).then(function () { say("Added."); }, function (e) { say(e && e.message ? e.message : "The wallet said no."); });
  });
  if (mine && field) mine.addEventListener("click", function () {
    window.ethereum.request({ method: "eth_requestAccounts" }).then(function (accounts) {
      if (accounts && accounts[0]) field.value = accounts[0];
    }, function () {});
  });
})();
