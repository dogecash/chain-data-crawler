#!/bin/bash

# Copyright (C) 2020 Matsuro Hadouken <matsuro-hadouken@protonmail.com>

# This file is free software as a special exception the author gives
# unlimited permission to copy and/or distribute it, with or without
# modifications, as long as this notice is preserved.

RPC_USER='rpc_username'
RPC_PW='rpc_password'

RPC_IP='127.0.0.1'
PORT='rpc_port'

DatabaseName='GRAFANA'
DatabaseUser='database_user'
DatabasePassword='database_password'

influx_host="127.0.0.1:8086"

Crawler_Log='/root/BACKEND/log.crawler.txt'

re='^[0-9]+$' # check digit ref

function checkHealth_Influx() {

    if ! [[ $(curl -s -XGET "$influx_host/health" | jq .message) =~ "ready for queries and writes" ]]; then

        log "ERROR: Database is not ready, exit now ..."

        exit 1

    fi

    log "InfluxDb ready for queries and writes, health check complete"

} # CHECH DATABASE HEALTH

function get_height() {

    HEIGHT=$(curl -s --user $RPC_USER:$RPC_PW --data-binary '{"jsonrpc": "1.0", "id":"curltest", "method": "getblockcount", "params": [] }' -H 'content-type: json;' http://"$RPC_IP":"$PORT" | jq -r .result)

} # GET HEIGHT FROM DAEMON IF THIS EVEN POSSIBLE

function WriteGenesis() {

    log "Writing Genesis block in to database ..."

    get_hash "0"

    get_block_data "$BLOCK_HASH"

    log "$BLOCK_DATA_JSON"

    IFS=', ' read -r -a array <<<"$BLOCK_DATA"

    INFLUX_FORMAT="block height=${array[1]},time_stamp=${array[0]},confirmations=${array[2]},size=${array[3]},version=${array[4]},difficulty=${array[5]},moneysupply=${array[6]},TxCount=$TxCount,BlockTime=0,TimeProtocolError=0"

    log "Reconstructed Genesis block: $INFLUX_FORMAT"

    PostData "$INFLUX_FORMAT"

    log "Genesis data successfully commited, parser ready."

    PREVIOUS_BLOCK_TIME="${array[0]}"

} # WRITE GENESIS DATA IN TO DATABASE, THIS IS ONE TIME INITIALISATION PROCESS

function get_hash() {

    BLOCK_HASH=$(curl -s --user $RPC_USER:$RPC_PW --data-binary '{"jsonrpc": "1.0", "id":"curltest", "method": "getblockhash", "params": ['"$1"'] }' -H 'content-type: json;' http://"$RPC_IP":"$PORT" | jq -r .result)

} # GET BLOCK HASH

function get_block_timestamp() {

    get_hash "$1"

    get_block_data "$BLOCK_HASH"

    LAST_REQUSTED_BLOCK_TIMESTAMP=$(echo "$BLOCK_DATA" | awk '{print $1;}')

} # RETURN BLOCK TIMESTAMP

function get_previous_block_timestamp() {

    get_block_timestamp "$1"

    CURRENT_BLOCK_TIMESTAMP="$LAST_REQUSTED_BLOCK_TIMESTAMP"

    PREVIOUS_BLOCK=$(expr "$1" - 1)

    get_block_timestamp "$PREVIOUS_BLOCK"

    PREVIOUS_BLOCK_TIME="$LAST_REQUSTED_BLOCK_TIMESTAMP" # <

    BlockTime=$(expr "$CURRENT_BLOCK_TIMESTAMP" - "$LAST_REQUSTED_BLOCK_TIMESTAMP")

} # GET TIMESTAMP FROM $LAST_HEIGHT_IN_DATABASE MUNUS PREVIOUS BLOCK TIMESTAMP, ONLY RUN WHEN SCRIPT INITIALIZED

function get_time() {

    BlockTime=$(expr "$1" - "$PREVIOUS_BLOCK_TIME")

    if [[ "$BlockTime" -gt 0 ]]; then
        TimeProtocolError='0'
    elif [[ "$BlockTime" -eq 0 ]]; then
        TimeProtocolError='1'
    else
        TimeProtocolError='2'
    fi # TimeProtocol error check

} # CALCULATE TIME BETWEEN BLOCKS / IF GENESIS SET GENESIS TIME, TIME PROTOCOL ERROR SET TO ZERO

function get_block_data() {

    BLOCK_DATA_JSON=$(curl -s --user $RPC_USER:$RPC_PW --data-binary '{"jsonrpc": "1.0", "id":"curltest", "method": "getblock", "params": ["'"$1"'"] }' -H 'content-type: json;' http://"$RPC_IP":"$PORT")

    BLOCK_DATA=$(echo "$BLOCK_DATA_JSON" | jq -r '.result | "\(.time) \(.height) \(.confirmations) \(.size) \(.version) \(.difficulty) \(.moneysupply)"')

    NODES=$(curl -s --user $RPC_USER:$RPC_PW --data-binary '{"jsonrpc": "1.0", "id":"curltest", "method": "getmasternodecount", "params": [] }' -H 'content-type: json;' http://"$RPC_IP":"$PORT")

    TxCount=$(echo "$BLOCK_DATA_JSON" | jq '.result | .tx | length')

} # GET BLOCK DATA IN JSON, PARSE REQUIRED INFORMATION TO CSV LIKE RAW STRING, COUNT TX IN BLOCK

function influx_constructer() {

    IFS=', ' read -r -a array <<<"$1"

    get_time "${array[0]}" # <<< HERE WE CALL GET_TIME FUNCTION WHICH RETURN $BlockTime, THIS VARIABLE IS PERMANENT AND GO TO DATABASE

    INFLUX_FORMAT="block height=${array[1]},time_stamp=${array[0]},confirmations=${array[2]},size=${array[3]},version=${array[4]},difficulty=${array[5]},moneysupply=${array[6]},TxCount=$TxCount,BlockTime=$BlockTime,TimeProtocolError=$TimeProtocolError"

    PREVIOUS_BLOCK_TIME="${array[0]}" # <<< WE GOING TO STORE CURRENT TIMESTAMP AS THE PREVIOUS_BLOCK_TIME_STAMP, THIS SHOULD NOT BE EVER OVERWRITE

} # RECONSTRUCT RAW BLOCK DATA IN TO INFLUX FORMAT

function PostData() {

    curl -i -XPOST "http://$influx_host/api/v2/write?bucket=$DatabaseName/chain_flow&precision=s" \
        --header "Authorization: Token $DatabaseUser:$DatabasePassword" \
        --data-raw "$1"

    log "$1"

} # POST TO DATABASE FUNCTION

function QueryLastHeight() {

    LastHeightQuery=$(curl -s -G http://$influx_host/query \
        -u "$DatabaseUser:$DatabasePassword" \
        --data-urlencode "db=$DatabaseName" \
        --data-urlencode "rp=chain_flow" \
        --data-urlencode "q=SELECT height FROM block GROUP BY * ORDER BY DESC LIMIT 1" | jq -r '.results[0] .series[0] .values[0] | .[1]')

} # QUERY LAST HEIGHT FROM DATABASE

function Initialize() {

    log "Query last height from database ..."

    QueryLastHeight

    if [[ "$LastHeightQuery" =~ "null" ]]; then

        log "Database doesn't contain any data, starting initialization process ..."

        WriteGenesis

        StartFromBlock=1

        log "Starting crawling service from block: 1 in 2 seconds ..." && sleep 2

        return 0

    fi

    log "Best height mentioned in database as: $LastHeightQuery"

    log "Requesting previous block timestamp ..."

    get_previous_block_timestamp "$LastHeightQuery"

    log "Time from previous block in seconds received: $BlockTime"

    StartFromBlock=$(($LastHeightQuery + 1))

    log "Starting crawling service from block $StartFromBlock in 2 seconds ..." && sleep 2

} # INITIALISATION FUNCTION

function get_nodes() {

    NODES_JSON=$(curl -s --user $RPC_USER:$RPC_PW --data-binary '{"jsonrpc": "1.0", "id":"curltest", "method": "getmasternodecount", "params": [] }' -H 'content-type: json;' http://"$RPC_IP":"$PORT")
    NODES=$(echo "$NODES_JSON" | jq -r '.result | "\(.total) \(.stable) \(.obfcompat) \(.enabled) \(.inqueue) \(.ipv4) \(.ipv6) \(.onion)"')

    IFS=', ' read -r -a array <<<"$NODES"

    INFLUX_NODE=",nodes_total=${array[0]},nodes_stable=${array[1]},nodes_obfcompat=${array[2]},nodes_enabled=${array[3]},nodes_inqueue=${array[4]},nodes_IPv4=${array[5]},nodes_IPv6=${array[6]},nodes_tor=${array[7]}"

}

function CrawlerLoop() {

    get_height # everything should be started from this, no exceptions. ( well, we check health already )

    for ((block = $StartFromBlock; block <= $HEIGHT; block++)); do

        get_hash "$block"

        get_block_data "$BLOCK_HASH"

        influx_constructer "$BLOCK_DATA"

        PostData "$INFLUX_FORMAT"

        log "$INFLUX_FORMAT" # DEBUG

    done

} # CRAWLER

function crawler_done() {

    get_height

    QueryLastHeight

    log "Crawler job done, starting watch service ..."

    log "Current chain height is $HEIGHT, last database height is $LastHeightQuery"

} # REPORT SITUATION AFTER CRAWLER DONE HIS JOB

function Crawler_d() {

    log "CRAWLER SERVICE IS ACTIVE, WATCHING CHAIN STATE"

    while true; do

        get_height

        if ! [[ $HEIGHT =~ $re ]]; then
            log "ERROR: DAEMON OFFLINE, EXIT 1"
            sleep 10 && exit 1
        fi # CHECK FOR ERRORS

        QueryLastHeight

        if [[ "$HEIGHT" -gt "$LastHeightQuery" ]]; then

            CrawlFromBlock=$(expr "$LastHeightQuery" + 1)

            for ((block = $CrawlFromBlock; block <= $HEIGHT; block++)); do

                get_hash "$block"

                get_block_data "$BLOCK_HASH"

                influx_constructer "$BLOCK_DATA"

                get_nodes

                PostData "$INFLUX_FORMAT$INFLUX_NODE"

                log "$INFLUX_FORMAT$INFLUX_NODE" # DEBUG

                sleep 0.5

            done

        fi # ADD BLOCK IF HEIGHT IS > THEN DATABASE HEIGHT

        sleep 4

    done

}

log() {

    echo "$1" >>"$Crawler_Log"
    echo >>"$Crawler_Log"

} # PRING LOG

checkHealth_Influx

Initialize

CrawlerLoop

crawler_done

Crawler_d
