#!/bin/bash

Nodes=(Alice Bob Carol Dave Ema Frank Geny)

# Store a {name: pubkey} and {name: balance} dictionary
declare -A ids
declare -A balances

closeall() {
    for node in ${Nodes[@]}
    do   
        echo "Closing Channes in" $node  
        docker-compose exec -T $node bash -c "lncli -n regtest closeallchannels"
    done
}

# Show All onchain balances of the nodes
# Often docker will not fund all the nodes, and it will miss some
# User needs to manually fund those nodes before further operations 
allbalances() {
    for node in ${Nodes[@]}
    do
        balance=$(docker-compose exec -T ${node} bash -c "lncli -n regtest walletbalance | jq -r .total_balance")
        echo "$node : $balance"
    done
}

# Open channel between two nodes
# openchannel [Node1] [Node2] [Amount]
openchannel() {
    from=$1
    to=$2
    amount=$3
    echo "Opencning Channel Between $from - $to : $amount sats"
    remote_key=$(docker-compose exec -T $to bash -c "lncli -n regtest getinfo | jq -r .identity_pubkey")
    docker-compose exec -T $from bash -c "lncli -n regtest connect ${remote_key}@$to"
    docker-compose exec -T $from bash -c "lncli -n regtest openchannel ${remote_key} $amount"
}

# Lightning pay between two nodes
# lnpay [Node1] [Amount] [Node2]
lnpay(){
    in_receiver=$3
    in_sender=$1
    in_amount=$2

    invoice=$(docker-compose exec -T $in_receiver bash -c "lncli -n regtest addinvoice $in_amount | jq -r .payment_request")
    docker-compose exec -T $in_sender lncli -n regtest payinvoice --inflight_updates -f ${invoice}
}

# Use a invoice to make payment
# Useful for sending a list of payments serially
# lnpayinvoice [Name] [invoice string] 
lnpayinvoice(){
    sender=$1
    invoice=$2
    docker-compose exec -T $sender lncli -n regtest payinvoice -f ${invoice}
}

# Close channel between two nodes
# closechannel [Name1] [Name2]
closechannel(){
    first=$1
    second=$2

    remote_key=$(docker-compose exec -T $second bash -c "lncli -n regtest getinfo | jq -r .identity_pubkey")
    outpoint=$(docker-compose exec -T $first bash -c "lncli -n regtest listchannels" | jq -r --arg remote_key $remote_key '.channels[] | select(.active==true and .remote_pubkey==$remote_key) | .channel_point' | tr ":" "\n") 
    docker-compose exec -T $first bash -c "lncli -n regtest closechannel $outpoint[0] $outpoint[1]"
}


# Check all the nodes are live and ensure adequate balance in them
 init() {
    for node in ${Nodes[@]}; do
        pubkey=$(docker-compose exec -T $node bash -c "lncli -n regtest getinfo | jq -r .identity_pubkey")
        balance=$(docker-compose exec -T ${node} bash -c "lncli -n regtest walletbalance | jq -r .total_balance")
        ids[$node]=$pubkey
        balances[$node]=$balance
    done

    echo "========== Nodes started ========== "
    for key in ${!dict[@]}; do
        echo "Name: $key || Punbkey: ${ids[$key]}"
    done

    echo "========== Checking for balances ========== "

    funded=false

    for key in ${!balances[@]}; do
        echo "Name: $key || Balance : ${balances[$key]}"
        if [ ${balances[$key]} -eq 0 ]; then
            funded=true
            echo "$key Does not have balance"
            
            required=$(( $ONCHAIN_FUND - ${balances[$key]} ))
            txid=$( fundnode $key $(( $required / 10**8 )) )
            echo "Funding $key : Txid: $txid"
        else
            echo "$key is funded"
        fi
        echo "=========="
    done
 
    if [ "$funded" = "true" ]; then
        echo "========== Waiting for 7 confs =========="
        waitforconf 2
        echo " ========== Updated Balances ========== "
        for node in ${Nodes[@]}; do
            balance=$(docker-compose exec -T ${node} bash -c "lncli -n regtest walletbalance | jq -r .total_balance")
            balances[$node]=$balance
            echo "Name: $node || Balance : $balance"
        done
    fi   
}

fundnode(){
    node=$1
    amount=$2
    address=$(docker-compose exec -T $node bash -c "lncli -n regtest newaddress p2wkh | jq -r .address")
    docker-compose exec -T bitcoind bash -c "bitcoin-cli -regtest -rpcuser=regtest -rpcpassword=regtest sendtoaddress $address $amount"
}

waitforconf() {
    confs=$1

    height=$(docker-compose exec -T bitcoind bash -c "bitcoin-cli -regtest -rpcuser=regtest -rpcpassword=regtest getblockchaininfo | jq -r .blocks")
    required=$(( $height + $confs))
    until [ $height -ge $required ] 
    do  
        echo "Waiting for $(( $required - $height )) more blocks....."
        height=$(docker-compose exec -T bitcoind bash -c "bitcoin-cli -regtest -rpcuser=regtest -rpcpassword=regtest getblockchaininfo | jq -r .blocks")
        sleep 10 
    done
}

# Given a node pubkey, translate back to its docker name
# translate-pk-to-name "[pubkey string]"
translate-pk-to-name(){
    pk=$1
    ${ids[$pk]}
}

# Get an invoice from Node
invoice() {
    node=$1
    amount=$2

    docker-compose exec -T ${node} bash -c "lncli -n regtest addinvoice $amount | jq -r .payment_request"    
}


# =========
# Start Program

# List ecxisting nodes for better output
init

#Set up a circular Network
capacity=1000000

openchannel Alice Bob $capacity
openchannel Bob Carol $capacity
openchannel Carol Dave $capacity
openchannel Dave Ema $capacity
openchannel Ema Frank $capacity
openchannel Frank Geny $capacity
openchannel Geny Alice $capacity

# wait for 15 blocks (150 secs) 
waitforconf 15

# Time a series of 20 payments
# Payment Alice -> Geny (6 hops) 
for i in {0..20}
do
    invoices+=($( invoice Geny 10000))
done

start=`date +%s`
for invoice in ${invoices[@]}
do
    echo "Paying invoice ---"
    lnpayinvoice Alice $invoice
done   
end=`date +%s`

runtime=$((end-start))

echo "Total execution time: ${runtime}"

# Close all channels
closeall
