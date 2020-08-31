#!/bin/sh -e

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

# Directories
# Allow access to /secrets/rpcpass.txt
# Allow access to LND directory (use /lnd/lnd.conf)
# Allow access to 'statuses'. /statuses/

# Output: /statuses/node-status-bitcoind-ready  (when ready, where a service can pick it up)
RPCUSER="${RPCUSER:-umbrelrpc}"
RPCPASS="${RPCPASS:-$(cat /secrets/rpcpass.txt)}"  # Default password location: /secrets/rpcpass.txt
SLEEPTIME="${SLEEPTIME:-3600}"                     # Default sleep: 3600
JSONRPCURL="${JSONRPCURL:-http://10.254.2.2:8332}" # Default RPC endpoint: http://10.254.2.2:8332
LND_CONTAINER_NAME="${LND_CONTAINER_NAME:-lnd}"    # Default Docker container name: lnd

PREV_MATCH=

disable_neutrino_if_synced() {
	echo 'Checking if LND is backed by Neutrino...'
	if ! grep -q 'bitcoin.node=neutrino' /lnd/lnd.conf; then
		echo 'Neutrino mode has been disabled'
		return 1
	fi

	echo 'If set to neutrino then lets check bitcoind'

	if ! INFO="$(curl --silent --user "$RPCUSER:$RPCPASS" --data-binary '{"jsonrpc": "1.0", "id":"switchme", "method": "getblockchaininfo", "params": [] }' "$JSONRPCURL")"; then
		echo "Error: 'getblockchaininfo' request to bitcoind failed"
		return
	fi

	if [ -z "$INFO" ] || err="$(jq -ner "$INFO | .error")"; then
		echo 'Error: from bitcoind'
		echo "${err:-Unknown error}"
		return
	fi

	INFO="$(jq -ne "$INFO | .result")"

	# Check if pruned
	if jq -ne "$INFO | .pruned == true"; then
		echo 'No need to switch from neutrino in pruned mode'
		return 1
	fi
	echo 'Not pruned'

	if jq -ne "$INFO | .headers - .blocks > 10"; then
		echo "Node isn't full synced yet"
		PREV_MATCH=
		return
	fi

	if [ -z "$PREV_MATCH" ]; then
		PREV_MATCH="$(jq -ne "$INFO | .headers")"
		echo 'Sync seems complete!  Will switch on next check.'
		return
	fi

	# Skip switch, if headers number didn't change since last check
	#	(possible network issue).
	if jq -ne "$INFO | .headers == $PREV_MATCH"; then
		echo 'Skipping switch for now: headers seem stale'
		return
	fi

	echo 'Bitcoind has been switched across to neutrino'
	touch /statuses/node-status-bitcoind-ready
	sed -Ei 's|(bitcoin.node)=neutrino|\1=bitcoind|g' /lnd/lnd.conf

	echo "Restarting LND"
	docker stop  "$LND_CONTAINER_NAME"
	docker start "$LND_CONTAINER_NAME"
}

while true; do
	disable_neutrino_if_synced
	sleep "$SLEEPTIME"
done
