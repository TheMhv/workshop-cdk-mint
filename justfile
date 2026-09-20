# Bitcoin Core + 3 LND nodes in a ring + CDK mint on regtest (Polar images).
#   lnd-one <-> lnd-two <-> lnd-three <-> lnd-one   (each channel 50/50 at start)
# Participants get lnd-two; the operator rebalances with `just send` / `just rebalance`.
# Requires: docker (compose v2), jq, just

set shell := ["bash", "-euo", "pipefail", "-c"]

nodes     := "lnd-one lnd-two lnd-three"
btc_cli   := "docker compose exec -T bitcoind bitcoin-cli -regtest -rpcuser=bitcoin -rpcpassword=bitcoin"
chan_size := "10000000"
chan_push := "5000000"
mint_url  := "http://localhost:8085"

# List all recipes
default:
    @just --list

# ---------------------------------------------------------------- lifecycle

# Start the containers (set WORKSHOP_IP=<lan ip> so lnd-two's TLS cert covers it)
up:
    docker compose up -d

# Stop the containers (state is kept in volumes)
down:
    docker compose down

# Stop the containers and delete all volumes
reset:
    docker compose down -v --remove-orphans

# Show container status
ps:
    @docker compose ps

# Follow logs, e.g. `just logs lnd-two`
logs *services:
    docker compose logs -f {{services}}

# Full bootstrap: start, fund wallets, open the 3 channels (safe to re-run)
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    just up
    just wait-bitcoind
    just init-wallet
    just wait-nodes
    if [ "$(just cli lnd-one listchannels | jq '.channels | length')" -gt 0 ]; then
      echo "Network already set up (lnd-one has channels)."
      exit 0
    fi
    just fund
    just connect lnd-one lnd-two
    just connect lnd-two lnd-three
    just connect lnd-three lnd-one
    just open-channel lnd-one lnd-two
    just open-channel lnd-two lnd-three
    just open-channel lnd-three lnd-one
    just mine 6
    just wait-channels
    echo
    echo "Done. Try: just liquidity  |  just demo"

# ---------------------------------------------------------------- waiting

# Wait until bitcoind answers RPC
wait-bitcoind:
    #!/usr/bin/env bash
    set -euo pipefail
    echo -n "waiting for bitcoind"
    for _ in $(seq 1 90); do
      if {{btc_cli}} getblockchaininfo >/dev/null 2>&1; then echo " ok"; exit 0; fi
      echo -n "."; sleep 1
    done
    echo " TIMEOUT"; exit 1

# Wait until every LND node is synced to chain
wait-nodes:
    #!/usr/bin/env bash
    set -euo pipefail
    for n in {{nodes}}; do
      echo -n "waiting for $n"
      ok=0
      for _ in $(seq 1 90); do
        if docker compose exec -T -u lnd "$n" lncli --network=regtest getinfo 2>/dev/null \
           | jq -e '.synced_to_chain == true' >/dev/null 2>&1; then ok=1; break; fi
        echo -n "."; sleep 1
      done
      [ "$ok" = 1 ] && echo " ok" || { echo " TIMEOUT"; exit 1; }
    done

# Wait until every node has 2 active channels and lnd-one sees all 3 in the graph
wait-channels:
    #!/usr/bin/env bash
    set -euo pipefail
    echo -n "waiting for channels + gossip"
    for _ in $(seq 1 120); do
      ok=1
      for n in {{nodes}}; do
        just cli "$n" listchannels --active_only | jq -e '.channels | length >= 2' >/dev/null 2>&1 || ok=0
      done
      just cli lnd-one describegraph | jq -e '.edges | length >= 3' >/dev/null 2>&1 || ok=0
      if [ "$ok" = 1 ]; then echo " ok"; exit 0; fi
      echo -n "."; sleep 1
    done
    echo " TIMEOUT (try: just mine 6)"; exit 1

# ---------------------------------------------------------------- bitcoin

# Run bitcoin-cli against the miner wallet, e.g. `just btc getbalance`
btc *args:
    @{{btc_cli}} -rpcwallet=miner {{args}}

# Create/load the miner wallet and mine until coinbase is spendable (101 blocks)
init-wallet:
    #!/usr/bin/env bash
    set -euo pipefail
    {{btc_cli}} createwallet miner >/dev/null 2>&1 || {{btc_cli}} loadwallet miner >/dev/null 2>&1 || true
    h=$({{btc_cli}} getblockcount)
    if [ "$h" -lt 101 ]; then just mine $((101 - h)); fi

# Mine N blocks (default 1)
mine n="1":
    @{{btc_cli}} -rpcwallet=miner generatetoaddress {{n}} "$({{btc_cli}} -rpcwallet=miner getnewaddress)" > /dev/null

# ---------------------------------------------------------------- lightning

# Run lncli on a node, e.g. `just cli lnd-one getinfo`
cli node *args:
    @docker compose exec -T -u lnd {{node}} lncli --network=regtest {{args}}

# Print a node's identity pubkey
pubkey node:
    @just cli {{node}} getinfo | jq -r .identity_pubkey

# Send BTC from the miner wallet to every LND wallet and confirm it
fund amount="5":
    #!/usr/bin/env bash
    set -euo pipefail
    for n in {{nodes}}; do
      addr=$(just cli "$n" newaddress p2wkh | jq -r .address)
      just btc sendtoaddress "$addr" {{amount}} >/dev/null
    done
    just mine 6
    for n in {{nodes}}; do
      echo -n "waiting for $n funds"
      for _ in $(seq 1 60); do
        if just cli "$n" walletbalance | jq -e '(.confirmed_balance | tonumber) > 0' >/dev/null 2>&1; then
          echo " ok"; break
        fi
        echo -n "."; sleep 1
      done
    done

# Connect node `from` to node `to` as a peer
connect from to:
    #!/usr/bin/env bash
    set -euo pipefail
    just cli {{from}} connect "$(just pubkey {{to}})@{{to}}:9735" >/dev/null 2>&1 || true

# Open a channel from -> to (sats); remember to `just mine 6` afterwards
open-channel from to amt=chan_size push=chan_push:
    @just cli {{from}} openchannel --node_key "$(just pubkey {{to}})" --local_amt {{amt}} --push_amt {{push}} > /dev/null

# Create an invoice on a node
invoice node amt="10000":
    @just cli {{node}} addinvoice --amt {{amt}}

# Pay an invoice from a node
pay node invoice:
    @just cli {{node}} payinvoice --force {{invoice}}

# ---------------------------------------------------------------- workshop / rebalancing

# Per-channel liquidity (sats) for every node
liquidity:
    #!/usr/bin/env bash
    set -euo pipefail
    for n in {{nodes}}; do
      echo "--- $n"
      just cli "$n" listchannels | jq -r '.channels[] | "with \(if .peer_alias != "" then .peer_alias else .remote_pubkey[0:8] end)  scid \(.scid // .chan_id)  local=\(.local_balance)  remote=\(.remote_balance)"'
    done

# Move sats: `to` creates an invoice, `from` pays it, e.g. `just send lnd-three lnd-two 500000`
send from to amt:
    #!/usr/bin/env bash
    set -euo pipefail
    inv=$(just cli {{to}} addinvoice --amt {{amt}} | jq -r .payment_request)
    just cli {{from}} payinvoice --force "$inv"

# Print the numeric chan_id of an active channel between `node` and `peer` (fails with diagnostics)
chan-id node peer:
    #!/usr/bin/env bash
    set -euo pipefail
    key=$(just pubkey {{peer}})
    id=$(just cli {{node}} listchannels | jq -r --arg pk "$key" '[.channels[] | select(.remote_pubkey == $pk and .active == true)][0] | (.scid // .chan_id) // empty')
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
      echo "no usable channel between {{node}} and {{peer}} (got: '$id')" >&2
      just cli {{node}} listchannels | jq -c '.channels[] | {chan_id, scid, remote_pubkey, active}' >&2
      exit 1
    fi
    echo "$id"

# Circular rebalance on one node: push `amt` sats out through its channel with `out_peer`
# and pull them back in through its channel with `in_peer` (works because of the ring).
# e.g. lnd-two is empty towards lnd-three: `just rebalance lnd-two lnd-one lnd-three 1000000`
rebalance node out_peer in_peer amt:
    #!/usr/bin/env bash
    set -euo pipefail
    out_chan=$(just chan-id {{node}} {{out_peer}})
    in_key=$(just pubkey {{in_peer}})
    inv=$(just cli {{node}} addinvoice --amt {{amt}} | jq -r .payment_request)
    echo "rebalancing {{node}}: out via chan $out_chan, back in via {{in_peer}}"
    just cli {{node}} payinvoice --force --allow_self_payment --outgoing_chan_id="$out_chan" --last_hop="$in_key" "$inv"

# Pay `to` from `from`, forcing the first hop through `via` (shows routing through the middle node)
route from via to amt="10000":
    #!/usr/bin/env bash
    set -euo pipefail
    out_chan=$(just cli {{from}} listchannels --peer "$(just pubkey {{via}})" | jq -r '.channels[0].chan_id')
    inv=$(just cli {{to}} addinvoice --amt {{amt}} | jq -r .payment_request)
    just cli {{from}} payinvoice --force --outgoing_chan_id "$out_chan" "$inv"

# Demo payment (there is a direct channel now, so this goes direct; see `route` for multi-hop)
demo from="lnd-one" to="lnd-three" amt="10000":
    @just send {{from}} {{to}} {{amt}}

# Bake a restricted macaroon for participants (can pay/receive/read; cannot open/close channels or spend on-chain)
bake node="lnd-two" ttl="14400":
    #!/usr/bin/env bash
    set -euo pipefail
    just cli {{node}} bakemacaroon --timeout {{ttl}} --save_to=/home/lnd/.lnd/workshop.macaroon \
      uri:/lnrpc.Lightning/GetInfo \
      uri:/lnrpc.Lightning/AddInvoice \
      uri:/lnrpc.Lightning/LookupInvoice \
      uri:/lnrpc.Lightning/DecodePayReq \
      uri:/lnrpc.Lightning/SendPaymentSync \
      uri:/routerrpc.Router/SendPaymentV2 \
      uri:/routerrpc.Router/TrackPaymentV2
    docker compose cp {{node}}:/home/lnd/.lnd/workshop.macaroon ./workshop.macaroon

# Copy lnd-two's TLS cert to the current directory (give it to participants with the macaroon)
tls-cert node="lnd-two":
    docker compose cp {{node}}:/home/lnd/.lnd/tls.cert ./tls.cert

# Balances and channel counts for all nodes
status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "bitcoind height: $({{btc_cli}} getblockcount)"
    for n in {{nodes}}; do
      echo "--- $n"
      just cli "$n" walletbalance  | jq -c '{onchain_sat: .confirmed_balance}'
      just cli "$n" channelbalance | jq -c '{local_sat: .local_balance.sat, remote_sat: .remote_balance.sat}'
      just cli "$n" listchannels   | jq -c '{channels: (.channels | length)}'
    done

# ---------------------------------------------------------------- cashu mint (CDK)

# Show the mint's /v1/info
mint-info:
    @curl -s {{mint_url}}/v1/info | jq

# Show the mint's keysets
mint-keysets:
    @curl -s {{mint_url}}/v1/keysets | jq

# Follow the mint's logs
mint-logs:
    docker compose logs -f mint

# Request a bolt11 mint quote (returns the invoice to pay)
mint-quote amt="1000":
    @curl -s -X POST {{mint_url}}/v1/mint/quote/bolt11 -H 'Content-Type: application/json' -d '{"amount": {{amt}}, "unit": "sat"}'

# Demo: request a quote and pay it from the workshop node (lnd-two -> lnd-three), then show the quote state
mint-demo amt="1000" payer="lnd-two":
    #!/usr/bin/env bash
    set -euo pipefail
    q=$(just mint-quote {{amt}})
    inv=$(echo "$q" | jq -r .request)
    id=$(echo "$q" | jq -r .quote)
    just cli {{payer}} payinvoice --force "$inv" >/dev/null
    sleep 2
    curl -s "{{mint_url}}/v1/mint/quote/bolt11/$id" | jq
