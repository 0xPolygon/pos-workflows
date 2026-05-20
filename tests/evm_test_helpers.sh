#!/bin/bash
# Shared constants and helpers for EVM opcode/precompile tests.
#
# Source this file from test scripts:
#   source "$SCRIPT_DIR/evm_test_helpers.sh"
#
# Provides:
#   evm-stress contract:
#     - deploy_evm_stress()             - idempotent contract deployment
#     - send_evm_stress_transactions()  - send all 26 action txs
#   polycli LoadTester contract:
#     - deploy_load_tester()            - deploy via polycli
#     - send_opcode_transactions()      - send 60 opcode txs
#     - send_precompile_transactions()  - send 10 precompile txs
#   Shared:
#     - wait_for_mining()               - poll until all txs mined
#
# All functions accept an optional rpc_url as first argument (defaults to $RPC_URL).
# Private key: ${PRIVATE_KEY:-$PK}
#
# Required globals before calling:
#   SENDER_ADDR, GAS_PRICE, TX_MINE_TIMEOUT
#   tx_hashes (assoc array), tx_status (assoc array), current_nonce

# ==============================================================================
# evm-stress contract constants
# ==============================================================================

CREATE2_DEPLOYER="0x4e59b44847b379578588920ca78fbf26c0b4956c"
EVM_STRESS_CONTRACT="0x863134579e4812F9d78081e9f519fAE9D01F2a10"

# Compiled from evm-stress.yul (https://github.com/agglayer/e2e/tree/main/core/contracts/evm-stress)
EVM_STRESS_DEPLOY_BYTECODE="0x6300001132630000001560003963000011326000f35f35602035906040355f9160648410611127575b5f821461111e575b91825f1461111157826001146110f357826002146110e457826003146110c857826004146110bd57826005146110a25782600614611097578260071461107c578260081461107057826009146110525782600a146110465782600b146110265782600c1461101a5782600d14610ffa5782600e14610fef5782600f14610fc95782601014610fbe5782601114610f9c5782601214610f925782601314610f735782601414610f685782601514610f495782601614610f3f5782601714610f1c5782601814610f0e5782601914610eea5782601a14610edb5782601b14610ebd5782601c14610eae5782601d14610e6a5782601e14610e595782601f14610e16575081602014610d945781602114610d035781602214610ceb5781602314610ccb5781602414610cb3575080602514610c945780602614610bdb5780602714610b155780602814610aef5780602914610abc5780602a14610a9b5780602b14610a6d5780602c146108c55780602d146107085780602e146106775780602f146105f057806030146105015780603114610405578060321461033e578060331461026a57610100146101d257644641494c215f5260205ffd5b60e01b7c0148c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f175f527f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e136020526619cde05b61626360c81b6040525f6060525f6080525f60a0527b0300000000000000000000000000000001000000000000000000000060c05260405f60d5818060095af1505b60205fa060205ff35b507fb7b8486d949d2beef140ca44d4c8c0524dd53a250fadefa477b2db15b7d387765f527fbeb9e3aacfdc1408bfe5f876d9ab6f7c50e06a2d5f68aa500b9a2ff8965875976020527fba72bb78539ef6de9188a0ce5e6d694e2b0cb5aeda35d7ccbb335f6cb5e97d886040527f32f6471f0e06a4830d24eaecfac34e12ad223211a89c42aaf11f44ce3364233a6060527f4cfeddbcb7aa6aad4226715338725398546cb20ba2e8b133b2abae61cfc624d06080525b805a1161032c5750610261565b60205f60a081806101005af15061031f565b50507fb7b8486d949d2beef140ca44d4c8c0524dd53a250fadefa477b2db15b7d387765f527fbeb9e3aacfdc1408bfe5f876d9ab6f7c50e06a2d5f68aa500b9a2ff8965875976020527fba72bb78539ef6de9188a0ce5e6d694e2b0cb5aeda35d7ccbb335f6cb5e97d886040527f32f6471f0e06a4830d24eaecfac34e12ad223211a89c42aaf11f44ce3364233a6060527f4cfeddbcb7aa6aad4226715338725398546cb20ba2e8b133b2abae61cfc624d060805260205f60a081806101005af150610261565b507f01e798154708fe7789429634053cbf9f99b619f9f084048927333fce637f549b5f527f564c0a11a0f704f4fc3e8acfe0f8245f0ad1347b378fbf96e206da11a5d363066020527f24d25032e67a7e6a4910df5834b8fe70e6bcfeeac0352434196bdf4b2485d5a16040527f8f59a8d2a1a625a17f3fea0fe5eb8c896db3764f3185481bc22f91b4aaffcca26060527f5f26936857bc3a7c2539ea8ec3a952b7873033e038326e87ed3e1276fd1402536080527ffa08e9fc25fb2d9a98527fc22a2c9612fbeafdad446cbc7bcdbdcd780af2c16a60a0525b805a116104f0575060e0515f52610261565b604060c0805f80600a5af1506104de565b50507f01e798154708fe7789429634053cbf9f99b619f9f084048927333fce637f549b5f527f564c0a11a0f704f4fc3e8acfe0f8245f0ad1347b378fbf96e206da11a5d363066020527f24d25032e67a7e6a4910df5834b8fe70e6bcfeeac0352434196bdf4b2485d5a16040527f8f59a8d2a1a625a17f3fea0fe5eb8c896db3764f3185481bc22f91b4aaffcca26060527f5f26936857bc3a7c2539ea8ec3a952b7873033e038326e87ed3e1276fd1402536080527ffa08e9fc25fb2d9a98527fc22a2c9612fbeafdad446cbc7bcdbdcd780af2c16a60a05260405f60c08180600a5af1506020515f52610261565b507c0148c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f5f527f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e136020526619cde05b61626360c81b6040525f6060525f6080525f60a052600360d81b60c0525b805a116106655750610261565b6040600460d55f8060095af150610658565b50507c0148c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f5f527f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e136020526619cde05b61626360c81b6040525f6060525f6080525f60a0527b0300000000000000000000000000000001000000000000000000000060c05260405f60d5818060095af150610261565b507f2cf44499d5d27bb186308b7af7af02ac5bc9eeb6a3d147c186b21fb1b76e18da5f527f2c0f001f52110ccfe69108924926e45f0b0c868df0e7bde1fe16d3242dc715f66020527f1fb19bb476f6b9e44e2a32234da8212f61cd63919354bc06aef31e3cfaff3ebc6040527f22606845ff186793914e03e21df544c34ffe2f2f3504de8a79d9159eca2d98d96060527f2bd368e28381e8eccb5fa81fc26cf3f048eea9abfdd85d7ed3ab3698d63e4f906080527f2fe02e47887507adf0ff1743cbac6ba291e66f59be6bd763950bb16041a0a85e60a052600160c0527f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4560e0527f1971ff0471b09fa93caaf13cbf443c1aede09cc4328f5a62aad45f40ec133eb4610100527f091058a3141822985733cbdddfed0fd8d6c104e9e9eff40bf5abfef9ab163bc7610120527f2a23af9a5ce2ba2796c1f4e453a370eb0af8c212d9dc9acd8fc02c2e907baea2610140527f23a8eb0b0996252cb548a4487da97b02422ebc0e834613f954de6c7e0afdc1fc610160525b805a116108b157506101a0515f52610261565b60206101a06101805f8060085af15061089e565b50507f2cf44499d5d27bb186308b7af7af02ac5bc9eeb6a3d147c186b21fb1b76e18da5f527f2c0f001f52110ccfe69108924926e45f0b0c868df0e7bde1fe16d3242dc715f66020527f1fb19bb476f6b9e44e2a32234da8212f61cd63919354bc06aef31e3cfaff3ebc6040527f22606845ff186793914e03e21df544c34ffe2f2f3504de8a79d9159eca2d98d96060527f2bd368e28381e8eccb5fa81fc26cf3f048eea9abfdd85d7ed3ab3698d63e4f906080527f2fe02e47887507adf0ff1743cbac6ba291e66f59be6bd763950bb16041a0a85e60a052600160c0527f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4560e0527f1971ff0471b09fa93caaf13cbf443c1aede09cc4328f5a62aad45f40ec133eb4610100527f091058a3141822985733cbdddfed0fd8d6c104e9e9eff40bf5abfef9ab163bc7610120527f2a23af9a5ce2ba2796c1f4e453a370eb0af8c212d9dc9acd8fc02c2e907baea2610140527f23a8eb0b0996252cb548a4487da97b02422ebc0e834613f954de6c7e0afdc1fc6101605260205f610180818060085af150610261565b5060015f52600260205260026040525b805a11610a8a5750610261565b60405f6080818060075af150610a7d565b505060015f526002602052600260405260405f6080818060075af150610261565b5060015f526002602052600160405260026060525b805a11610ade5750610261565b60405f6080818060065af150610ad1565b505060015f5260026020526001604052600260605260405f6080818060065af150610261565b5060405f526001602052604080527fe09ad9675465c53a109fac66a445c91b292d2bb2c5268addb30cd82f80fcb0036060527f3ff97c80a5fc6f39193ae969c6ede6710a6b7ac27078a06d90ef1c72e5c85fb56080527f02fc9e1f6beb81516545975218075ec2af118cd8798df6e08a147c60fd6095ac60a0527f2bb02c2908cf4dd7c81f11c289e4bce98f3553768f392a80ce22bf5c4f4a248c60c052606b60f81b60e0525b805a11610bc95750610261565b60405f610100818060055af150610bbc565b505060405f526001602052604080527fe09ad9675465c53a109fac66a445c91b292d2bb2c5268addb30cd82f80fcb0036060527f3ff97c80a5fc6f39193ae969c6ede6710a6b7ac27078a06d90ef1c72e5c85fb56080527f02fc9e1f6beb81516545975218075ec2af118cd8798df6e08a147c60fd6095ac60a0527f2bb02c2908cf4dd7c81f11c289e4bce98f3553768f392a80ce22bf5c4f4a248c60c052606b60f81b60e05260405f610100818060055af150610261565b505b805a11610ca35750610261565b60205f81818060035af150610c96565b5f9150826020939184925201818060035af150610261565b50505b805a11610cdb5750610261565b60205f81818060025af150610cce565b5f9150826020939184925201818060025af150610261565b50507f456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef35f52601c6020527f9242685bf161793cc25603c231bc2f568eb630ea16aa137d2664ac80388256086040527f4f8ae3bd7535248d0bd448298cc2e2071e56992d0774dc340c368ae950852ada6060525b805a11610d835750610261565b60205f6080818060015af150610d76565b50505f6080818060016020957f456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef38352601c87527f9242685bf161793cc25603c231bc2f568eb630ea16aa137d2664ac80388256086040527f4f8ae3bd7535248d0bd448298cc2e2071e56992d0774dc340c368ae950852ada606052f150610261565b929150507f6300000003630000001560003963000000036000f35f5ff300000000000000005f525b805a11610e4d57505f52610261565b9060185f80f590610e3e565b50825f939250528180f55f52610261565b929150507f6300000003630000001560003963000000036000f35f5ff300000000000000005f525b805a11610ea157505f52610261565b905060185f80f090610e92565b50905081525f80f05f52610261565b5050505b805a11610ece5750610261565b5f808080602081a4610ec1565b5050505f8080809381a4610261565b92809250525b805a11610eff57505f52610261565b9080602080925f5e0190610ef0565b509050815260205f5e610261565b5050505f905b805a11610f3157505f52610261565b908080600192550190610f22565b5091905055610261565b5050505f905b805a11610f5e57505f52610261565b9060010190610f4f565b505050545f52610261565b5090505f5b825a11610f8757505050610261565b818152602001610f78565b5091905052610261565b509190505f9181525b805a11610fb457505f52610261565b9060200190610fa5565b505050515f52610261565b9291505043905b805a11610fe05750505f52610261565b90915060018240920390610fd0565b505050405f52610261565b9291505b815a1161100e5750505f52610261565b809192503f9190610ffe565b509150503f5f52610261565b9291505b815a1161103a5750505f52610261565b809192503b919061102a565b509150503b5f52610261565b509190505b805a11611065575050610261565b60205f80843c611057565b505f915081903c610261565b5050505b805a1161108d5750610261565b60205f8039611080565b5050505f8039610261565b5050505b805a116110b35750610261565b60205f80376110a6565b5050505f8037610261565b5050505b805a116110d95750610261565b60205f205f526110cc565b50905081526020205f52610261565b929150505b805a1161110757505f52610261565b90600101906110f8565b5050506001015f52610261565b9050309061001b565b92506127109261001356"

ACTION_CODES=(
  0x0000 0x0002 0x0004 0x0006 0x0008 0x000a 0x000c 0x000e
  0x0010 0x0012 0x0014 0x0016 0x0018 0x001a 0x001c 0x001e
  0x0020 0x0022 0x0024 0x0026 0x0028 0x002a 0x002c 0x002e
  0x0030 0x0032
)

declare -A EVM_STRESS_ACTIONS=(
  [0x0000]="ADD"
  [0x0002]="KECCAK256"
  [0x0004]="CALLDATACOPY"
  [0x0006]="CODECOPY"
  [0x0008]="EXTCODECOPY"
  [0x000a]="EXTCODESIZE"
  [0x000c]="EXTCODEHASH"
  [0x000e]="BLOCKHASH"
  [0x0010]="MLOAD"
  [0x0012]="MSTORE"
  [0x0014]="SLOAD"
  [0x0016]="SSTORE"
  [0x0018]="MCOPY"
  [0x001a]="LOG4"
  [0x001c]="CREATE"
  [0x001e]="CREATE2"
  [0x0020]="ECRECOVER"
  [0x0022]="SHA256"
  [0x0024]="RIPEMD160"
  [0x0026]="MODEXP"
  [0x0028]="ECADD"
  [0x002a]="ECMUL"
  [0x002c]="ECPAIRING"
  [0x002e]="BLAKE2F"
  [0x0030]="POINT_EVAL"
  [0x0032]="P256VERIFY"
)

# ==============================================================================
# polycli LoadTester constants
# ==============================================================================

OPCODES=(
  "testADD" "testMUL" "testSUB" "testDIV" "testSDIV"
  "testMOD" "testSMOD" "testADDMOD" "testMULMOD" "testEXP"
  "testSIGNEXTEND" "testLT" "testGT" "testSLT" "testSGT"
  "testEQ" "testISZERO" "testAND" "testOR" "testXOR"
  "testNOT" "testBYTE" "testSHL" "testSHR" "testSAR"
  "testSHA3" "testADDRESS" "testBALANCE" "testORIGIN" "testCALLER"
  "testCALLVALUE" "testCALLDATALOAD" "testCALLDATASIZE" "testCALLDATACOPY"
  "testCODESIZE" "testCODECOPY" "testGASPRICE" "testEXTCODESIZE"
  "testRETURNDATASIZE" "testBLOCKHASH" "testCOINBASE"
  "testTIMESTAMP" "testNUMBER" "testDIFFICULTY" "testGASLIMIT" "testCHAINID"
  "testSELFBALANCE" "testBASEFEE" "testMLOAD" "testMSTORE"
  "testMSTORE8" "testSLOAD" "testSSTORE" "testMSIZE" "testGAS"
  "testLOG0" "testLOG1" "testLOG2" "testLOG3" "testLOG4"
)

PRECOMPILE_NAMES=("testSHA256" "testRipemd160" "testIdentity" "testBlake2f" "testModExp" "testECAdd" "testECMul" "testECPairing" "testECRecover" "testP256Verify")

MODEXP_INPUT="0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001020305"
ECADD_INPUT="0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
ECMUL_INPUT="0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002"
ECRECOVER_INPUT="0x456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef3000000000000000000000000000000000000000000000000000000000000001c9242685bf161793cc25603c231bc2f568eb630ea16aa137d2664ac80388256084f8ae3bd7535248d0bd448298cc2e2071e56992d0774dc340c368ae950852ada"
P256_INPUT="0x4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4da73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d604aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff37618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e"

declare -A PRECOMPILES=(
  ["testSHA256"]="testSHA256(bytes)|0xdeadbeef"
  ["testRipemd160"]="testRipemd160(bytes)|0xdeadbeef"
  ["testIdentity"]="testIdentity(bytes)|0xdeadbeef"
  ["testBlake2f"]="testBlake2f(bytes)|0x"
  ["testModExp"]="testModExp(bytes)|$MODEXP_INPUT"
  ["testECAdd"]="testECAdd(bytes)|$ECADD_INPUT"
  ["testECMul"]="testECMul(bytes)|$ECMUL_INPUT"
  ["testECPairing"]="testECPairing(bytes)|0x"
  ["testECRecover"]="testECRecover(bytes)|$ECRECOVER_INPUT"
  ["testP256Verify"]="testP256Verify(bytes)|$P256_INPUT"
)

# ==============================================================================
# Shared send helper with retry
# ==============================================================================

# Send a transaction with retry on transient failures.
# Handles nonce desync by re-fetching from RPC on failure.
# Sets TX_RESULT to the tx hash on success, empty on failure.
# Updates current_nonce on success.
#
# Usage: cast_send_with_retry <rpc_url> <private_key> <cast send args...>
cast_send_with_retry() {
  local rpc_url="$1"
  local private_key="$2"
  shift 2

  local max_retries=3
  local attempt=0
  TX_RESULT=""

  while [ $attempt -lt $max_retries ]; do
    local tx_hash
    tx_hash=$(cast send "$@" \
      --rpc-url "$rpc_url" \
      --private-key "$private_key" \
      --gas-price "$GAS_PRICE" \
      --nonce "$current_nonce" \
      --legacy \
      --async 2> /dev/null) || true

    if [[ "$tx_hash" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
      TX_RESULT="$tx_hash"
      current_nonce=$((current_nonce + 1))
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $attempt -lt $max_retries ]; then
      sleep 1
      current_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending 2> /dev/null) || true
    fi
  done

  # Final nonce re-sync after all retries exhausted
  current_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending 2> /dev/null) || true
  return 1
}

# ==============================================================================
# evm-stress functions
# ==============================================================================

# Deploy the evm-stress contract idempotently.
# Sets CONTRACT_ADDR on success.
deploy_evm_stress() {
  local private_key="${PRIVATE_KEY:-$PK}"
  local rpc_url="${1:-$RPC_URL}"

  local existing_code
  existing_code=$(cast code "$EVM_STRESS_CONTRACT" --rpc-url "$rpc_url" 2> /dev/null) || true
  if [ -n "$existing_code" ] && [ "$existing_code" != "0x" ]; then
    echo "evm-stress already deployed at: $EVM_STRESS_CONTRACT"
    CONTRACT_ADDR="$EVM_STRESS_CONTRACT"
    return 0
  fi

  echo "Deploying evm-stress contract..."

  local deployer_code
  deployer_code=$(cast code "$CREATE2_DEPLOYER" --rpc-url "$rpc_url" 2> /dev/null) || true
  if [ -n "$deployer_code" ] && [ "$deployer_code" != "0x" ]; then
    echo "Using CREATE2 deployer at $CREATE2_DEPLOYER"
    local salt="0000000000000000000000000000000000000000000000000000000000000000"
    local deploy_data="0x${salt}${EVM_STRESS_DEPLOY_BYTECODE#0x}"

    local deploy_nonce
    deploy_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending)
    cast send "$CREATE2_DEPLOYER" "$deploy_data" \
      --rpc-url "$rpc_url" \
      --private-key "$private_key" \
      --gas-price "$GAS_PRICE" \
      --gas-limit 5000000 \
      --nonce "$deploy_nonce" \
      --legacy 2>&1

    CONTRACT_ADDR="$EVM_STRESS_CONTRACT"
  else
    echo "CREATE2 deployer not available, using standard CREATE"
    local deploy_nonce
    deploy_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending)
    if ! [[ "$deploy_nonce" =~ ^[0-9]+$ ]]; then
      echo "Failed to get nonce for deployment"
      return 1
    fi

    cast send \
      --rpc-url "$rpc_url" \
      --private-key "$private_key" \
      --gas-price "$GAS_PRICE" \
      --gas-limit 5000000 \
      --nonce "$deploy_nonce" \
      --legacy \
      --create "$EVM_STRESS_DEPLOY_BYTECODE" 2>&1

    CONTRACT_ADDR=$(cast compute-address "$SENDER_ADDR" --nonce "$deploy_nonce" | grep -oE "0x[a-fA-F0-9]{40}")
  fi

  if [ -z "$CONTRACT_ADDR" ]; then
    echo "Failed to determine contract address"
    return 1
  fi

  sleep 2
  local contract_code
  contract_code=$(cast code "$CONTRACT_ADDR" --rpc-url "$rpc_url" 2> /dev/null) || true
  if [ -z "$contract_code" ] || [ "$contract_code" = "0x" ]; then
    echo "Contract not deployed at expected address: $CONTRACT_ADDR"
    return 1
  fi

  echo "evm-stress deployed at: $CONTRACT_ADDR"
  return 0
}

# Send one transaction per evm-stress action (26 total).
# Populates tx_hashes[] and tx_status[], updates current_nonce.
send_evm_stress_transactions() {
  local private_key="${PRIVATE_KEY:-$PK}"
  local rpc_url="${1:-$RPC_URL}"

  echo ""
  echo "Sending evm-stress transactions (26 actions)..."

  current_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending)
  local sent_count=0

  for action in "${ACTION_CODES[@]}"; do
    local name="${EVM_STRESS_ACTIONS[$action]}"
    local calldata
    calldata=$(cast abi-encode 'f(uint256,uint256,uint256)' "$action" 10000 0)

    if cast_send_with_retry "$rpc_url" "$private_key" \
      "$CONTRACT_ADDR" "$calldata" --gas-limit 5000000; then
      tx_hashes["$name"]="$TX_RESULT"
      tx_status["$name"]="pending"
      sent_count=$((sent_count + 1))
    else
      tx_status["$name"]="send_failed"
    fi
  done

  echo "Sent $sent_count/26 evm-stress transactions"
}

# ==============================================================================
# polycli LoadTester functions
# ==============================================================================

# Deploy the polycli LoadTester contract.
# Sets LOAD_TESTER_ADDR on success.
deploy_load_tester() {
  local private_key="${PRIVATE_KEY:-$PK}"
  local rpc_url="${1:-$RPC_URL}"

  echo ""
  echo "Deploying LoadTester contract..."

  local deploy_nonce
  deploy_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url")
  if ! [[ "$deploy_nonce" =~ ^[0-9]+$ ]]; then
    echo "Failed to get nonce for deployment"
    return 1
  fi
  echo "Deploying with nonce: $deploy_nonce"

  if ! polycli loadtest --rpc-url "$rpc_url" \
    --private-key "$private_key" \
    --verbosity 500 \
    --requests 1 \
    --gas-price "$GAS_PRICE" \
    --mode d 2>&1; then
    echo "polycli loadtest failed"
    return 1
  fi

  LOAD_TESTER_ADDR=$(cast compute-address "$SENDER_ADDR" --nonce "$deploy_nonce" | grep -oE "0x[a-fA-F0-9]{40}")

  if [ -z "$LOAD_TESTER_ADDR" ]; then
    echo "Failed to compute contract address"
    return 1
  fi

  local contract_code
  contract_code=$(cast code "$LOAD_TESTER_ADDR" --rpc-url "$rpc_url" 2> /dev/null)
  if [ -z "$contract_code" ] || [ "$contract_code" = "0x" ]; then
    echo "Contract not deployed at expected address: $LOAD_TESTER_ADDR"
    return 1
  fi
  echo "LoadTester deployed at: $LOAD_TESTER_ADDR"
  return 0
}

# Send 60 opcode transactions to the LoadTester contract.
# Populates tx_hashes[] and tx_status[], updates current_nonce.
send_opcode_transactions() {
  local private_key="${PRIVATE_KEY:-$PK}"
  local rpc_url="${1:-$RPC_URL}"

  echo ""
  echo "Sending EVM opcode transactions (60 functions)..."

  current_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending)
  local sent_count=0

  for opcode in "${OPCODES[@]}"; do
    if cast_send_with_retry "$rpc_url" "$private_key" \
      "$LOAD_TESTER_ADDR" "${opcode}(uint256)" 10; then
      tx_hashes["$opcode"]="$TX_RESULT"
      tx_status["$opcode"]="pending"
      sent_count=$((sent_count + 1))
    else
      tx_status["$opcode"]="send_failed"
    fi
  done
  echo "Sent $sent_count/60 opcode transactions"
}

# Send 10 precompile transactions to the LoadTester contract.
# Populates tx_hashes[] and tx_status[], updates current_nonce.
send_precompile_transactions() {
  local private_key="${PRIVATE_KEY:-$PK}"
  local rpc_url="${1:-$RPC_URL}"

  echo ""
  echo "Sending precompile transactions (10 functions)..."

  local precompile_sent=0
  current_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$rpc_url" --block pending)

  for name in "${PRECOMPILE_NAMES[@]}"; do
    IFS='|' read -r sig args <<< "${PRECOMPILES[$name]}"
    if cast_send_with_retry "$rpc_url" "$private_key" \
      "$LOAD_TESTER_ADDR" "$sig" $args; then
      tx_hashes["$name"]="$TX_RESULT"
      tx_status["$name"]="pending"
      precompile_sent=$((precompile_sent + 1))
    else
      tx_status["$name"]="send_failed"
    fi
  done
  echo "Sent $precompile_sent/10 precompile transactions"
}

# ==============================================================================
# Shared functions
# ==============================================================================

# Wait for all transactions in tx_hashes[] to be mined.
# Sets tx_status[name]="timeout" for unmined transactions.
wait_for_mining() {
  local rpc_url="${1:-$RPC_URL}"

  echo ""
  echo "Waiting for transactions to be mined..."

  local max_wait=$TX_MINE_TIMEOUT
  local waited=0
  local pending_txs=("${!tx_hashes[@]}")

  while [ ${#pending_txs[@]} -gt 0 ] && [ $waited -lt $max_wait ]; do
    local still_pending=()
    for test_name in "${pending_txs[@]}"; do
      local tx_hash="${tx_hashes[$test_name]}"
      local receipt
      receipt=$(timeout 30 cast receipt "$tx_hash" --rpc-url "$rpc_url" --json 2> /dev/null)
      if [ -z "$receipt" ] || [ "$receipt" = "null" ]; then
        still_pending+=("$test_name")
      fi
    done
    pending_txs=("${still_pending[@]}")

    if [ ${#pending_txs[@]} -gt 0 ]; then
      echo "Waiting for ${#pending_txs[@]} transactions... ($waited/$max_wait s)"
      sleep 2
      waited=$((waited + 2))
    fi
  done

  if [ ${#pending_txs[@]} -gt 0 ]; then
    echo "Timeout: ${#pending_txs[@]} transactions not mined after ${max_wait}s"
    for test_name in "${pending_txs[@]}"; do
      tx_status["$test_name"]="timeout"
    done
  else
    echo "All transactions mined"
  fi
}
