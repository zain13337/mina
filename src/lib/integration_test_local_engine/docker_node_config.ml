open Core_kernel
open Async
open Integration_test_lib
open Docker_compose

module PortManager = struct
  let mina_internal_rest_port = 3085

  let mina_internal_client_port = 8301

  let mina_internal_metrics_port = 10001

  let mina_internal_server_port = 3086

  let mina_internal_external_port = 10101

  let postgres_internal_port = 5432

  type t =
    { mutable available_ports : int list
    ; mutable used_ports : int list
    ; min_port : int
    ; max_port : int
    }

  let create ~min_port ~max_port =
    let available_ports = List.range min_port max_port in
    { available_ports; used_ports = []; min_port; max_port }

  let allocate_port t =
    match t.available_ports with
    | [] ->
        failwith "No available ports"
    | port :: rest ->
        t.available_ports <- rest ;
        t.used_ports <- port :: t.used_ports ;
        port

  let allocate_ports_for_node t =
    let rest_port_source = allocate_port t in
    let client_port_source = allocate_port t in
    let metrics_port_source = allocate_port t in
    [ { Dockerfile.Service.Port.published = rest_port_source
      ; target = mina_internal_rest_port
      }
    ; { published = client_port_source; target = mina_internal_client_port }
    ; { published = metrics_port_source; target = mina_internal_metrics_port }
    ]

  let release_port t port =
    t.used_ports <- List.filter t.used_ports ~f:(fun p -> p <> port) ;
    t.available_ports <- port :: t.available_ports

  let get_latest_used_port t =
    match t.used_ports with [] -> failwith "No used ports" | port :: _ -> port
end

module Base_node_config = struct
  type t =
    { peer : string option
    ; log_level : string
    ; log_snark_work_gossip : bool
    ; log_txn_pool_gossip : bool
    ; generate_genesis_proof : bool
    ; client_port : string
    ; rest_port : string
    ; external_port : string
    ; metrics_port : string
    ; runtime_config_path : string option
    ; libp2p_key_path : string
    ; libp2p_secret : string
    ; start_filtered_logs : string list
    }
  [@@deriving to_yojson]

  let container_runtime_config_path = "/root/runtime_config.json"

  let container_entrypoint_path = "/root/entrypoint.sh"

  let container_keys_path = "/root/keys"

  let container_libp2p_key_path = container_keys_path ^ "/libp2p_key"

  let entrypoint_script =
    ( "entrypoint.sh"
    , {|#!/bin/bash
  # This file is auto-generated by the local integration test framework.
  # Path to the libp2p_key file
  LIBP2P_KEY_PATH="|}
      ^ container_libp2p_key_path
      ^ {|"
  # Generate keypair and set permissions if libp2p_key does not exist
  if [ ! -f "$LIBP2P_KEY_PATH" ]; then
    mina libp2p generate-keypair --privkey-path $LIBP2P_KEY_PATH
  fi
  /bin/chmod -R 700 |}
      ^ container_keys_path ^ {|/
  # Import any compatible keys in |}
      ^ container_keys_path ^ {|/*, excluding certain keys
  for key_file in |}
      ^ container_keys_path
      ^ {|/*; do
    # Exclude specific keys (e.g., libp2p keys)
    if [[ $(basename "$key_file") != "libp2p_key" ]]; then
      mina accounts import -config-directory /root/.mina-config -privkey-path "$key_file"
    fi
  done
  # Execute the puppeteer script
  exec /mina_daemon_puppeteer.py "$@"
  |}
    )

  let runtime_config_volume : Docker_compose.Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "runtime_config.json"
    ; target = container_runtime_config_path
    }

  let entrypoint_volume : Docker_compose.Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "entrypoint.sh"
    ; target = container_entrypoint_path
    }

  let default ?(runtime_config_path = None) ?(peer = None)
      ?(start_filtered_logs = []) =
    { runtime_config_path
    ; peer
    ; log_snark_work_gossip = true
    ; log_txn_pool_gossip = true
    ; generate_genesis_proof = true
    ; log_level = "Debug"
    ; client_port = PortManager.mina_internal_client_port |> Int.to_string
    ; rest_port = PortManager.mina_internal_rest_port |> Int.to_string
    ; metrics_port = PortManager.mina_internal_metrics_port |> Int.to_string
    ; external_port = PortManager.mina_internal_external_port |> Int.to_string
    ; libp2p_key_path = container_libp2p_key_path
    ; libp2p_secret = ""
    ; start_filtered_logs
    }

  let to_docker_env_vars t =
    [ ("DAEMON_REST_PORT", t.rest_port)
    ; ("DAEMON_CLIENT_PORT", t.client_port)
    ; ("DAEMON_METRICS_PORT", t.metrics_port)
    ; ("DAEMON_EXTERNAL_PORT", t.external_port)
    ; ("RAYON_NUM_THREADS", "8")
    ; ("MINA_PRIVKEY_PASS", "naughty blue worm")
    ; ("MINA_LIBP2P_PASS", "")
    ]

  let to_list t =
    let base_args =
      [ "-log-level"
      ; t.log_level
      ; "-log-snark-work-gossip"
      ; Bool.to_string t.log_snark_work_gossip
      ; "-log-txn-pool-gossip"
      ; Bool.to_string t.log_txn_pool_gossip
      ; "-generate-genesis-proof"
      ; Bool.to_string t.generate_genesis_proof
      ; "-client-port"
      ; t.client_port
      ; "-rest-port"
      ; t.rest_port
      ; "-external-port"
      ; t.external_port
      ; "-metrics-port"
      ; t.metrics_port
      ; "--libp2p-keypair"
      ; t.libp2p_key_path
      ; "-log-json"
      ; "--insecure-rest-server"
      ; "-external-ip"
      ; "0.0.0.0"
      ]
    in
    let peer_args =
      match t.peer with Some peer -> [ "-peer"; peer ] | None -> []
    in
    let start_filtered_logs_args =
      List.concat
        (List.map t.start_filtered_logs ~f:(fun log ->
             [ "--start-filtered-logs"; log ] ) )
    in
    let runtime_config_path =
      match t.runtime_config_path with
      | Some path ->
          [ "-config-file"; path ]
      | None ->
          []
    in
    List.concat
      [ base_args; runtime_config_path; peer_args; start_filtered_logs_args ]
end

module Block_producer_config = struct
  type config =
    { keypair : Network_keypair.t
    ; priv_key_path : string
    ; enable_flooding : bool
    ; enable_peer_exchange : bool
    ; base_config : Base_node_config.t
    }
  [@@deriving to_yojson]

  type t =
    { service_name : string
    ; config : config
    ; docker_config : Dockerfile.Service.t
    }
  [@@deriving to_yojson]

  let create_cmd config =
    let base_args = Base_node_config.to_list config.base_config in
    let block_producer_args =
      [ "daemon"
      ; "-block-producer-key"
      ; config.priv_key_path
      ; "-enable-flooding"
      ; config.enable_flooding |> Bool.to_string
      ; "-enable-peer-exchange"
      ; config.enable_peer_exchange |> Bool.to_string
      ]
    in
    List.concat [ block_producer_args; base_args ]

  let create_docker_config ~image ~entrypoint ~ports ~volumes ~environment
      ~config =
    { Dockerfile.Service.image
    ; command = create_cmd config
    ; entrypoint
    ; ports
    ; environment
    ; volumes
    }

  let create ~service_name ~image ~ports ~volumes ~config =
    let entrypoint = Some [ "/root/entrypoint.sh" ] in
    let environment = Base_node_config.to_docker_env_vars config.base_config in
    let docker_config =
      create_docker_config ~image ~ports ~volumes ~environment ~entrypoint
        ~config
    in
    { service_name; config; docker_config }
end

module Seed_config = struct
  let peer_id = "12D3KooWMg66eGtSEx5UZ9EAqEp3W7JaGd6WTxdRFuqhskRN55dT"

  let libp2p_keypair =
    {|{"box_primitive":"xsalsa20poly1305","pw_primitive":"argon2i","nonce":"7Bbvv2wZ6iCeqVyooU9WR81aygshMrLdXKieaHT","pwsalt":"Bh1WborqSwdzBi7m95iZdrCGspSf","pwdiff":[134217728,6],"ciphertext":"8fgvt4eKSzF5HMr1uEZARVHBoMgDKTx17zV7STVQyhyyEz1SqdH4RrU51MFGMPZJXNznLfz8RnSPsjrVqhc1CenfSLLWP5h7tTn86NbGmzkshCNvUiGEoSb2CrSLsvJsdn13ey9ibbZfdeXyDp9y6mKWYVmefAQLWUC1Kydj4f4yFwCJySEttAhB57647ewBRicTjdpv948MjdAVNf1tTxms4VYg4Jb3pLVeGAPaRtW5QHUkA8LwN5fh3fmaFk1mRudMd67UzGdzrVBeEHAp4zCnN7g2iVdWNmwN3"}|}

  let create_libp2p_peer ~peer_name ~external_port =
    Printf.sprintf "/dns4/%s/tcp/%d/p2p/%s" peer_name external_port peer_id

  type config =
    { archive_address : string option; base_config : Base_node_config.t }
  [@@deriving to_yojson]

  type t =
    { service_name : string
    ; config : config
    ; docker_config : Dockerfile.Service.t
    }
  [@@deriving to_yojson]

  let seed_libp2p_keypair : Docker_compose.Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "keys/libp2p_key"
    ; target = Base_node_config.container_libp2p_key_path
    }

  let create_cmd config =
    let base_args = Base_node_config.to_list config.base_config in
    let seed_args =
      match config.archive_address with
      | Some archive_address ->
          [ "daemon"; "-seed"; "-archive-address"; archive_address ]
      | None ->
          [ "daemon"; "-seed" ]
    in
    List.concat [ seed_args; base_args ]

  let create_docker_config ~image ~entrypoint ~ports ~volumes ~environment
      ~config =
    { Dockerfile.Service.image
    ; command = create_cmd config
    ; entrypoint
    ; ports
    ; environment
    ; volumes
    }

  let create ~service_name ~image ~ports ~volumes ~config =
    let entrypoint = Some [ "/root/entrypoint.sh" ] in
    let environment = Base_node_config.to_docker_env_vars config.base_config in
    let docker_config =
      create_docker_config ~image ~ports ~volumes ~environment ~entrypoint
        ~config
    in
    { service_name; config; docker_config }
end

module Snark_worker_config = struct
  type config =
    { daemon_address : string
    ; daemon_port : string
    ; proof_level : string
    ; base_config : Base_node_config.t
    }
  [@@deriving to_yojson]

  type t =
    { service_name : string
    ; config : config
    ; docker_config : Dockerfile.Service.t
    }
  [@@deriving to_yojson]

  let create_cmd config =
    [ "internal"
    ; "snark-worker"
    ; "-proof-level"
    ; config.proof_level
    ; "-daemon-address"
    ; config.daemon_address ^ ":" ^ config.daemon_port
    ; "--shutdown-on-disconnect"
    ; "false"
    ]

  let create_docker_config ~image ~entrypoint ~ports ~volumes ~environment
      ~config =
    { Dockerfile.Service.image
    ; command = create_cmd config
    ; entrypoint
    ; ports
    ; environment
    ; volumes
    }

  let create ~service_name ~image ~ports ~volumes ~config =
    let entrypoint = Some [ "/root/entrypoint.sh" ] in
    let environment = Base_node_config.to_docker_env_vars config.base_config in
    let docker_config =
      create_docker_config ~image ~ports ~volumes ~environment ~entrypoint
        ~config
    in
    { service_name; config; docker_config }
end

module Snark_coordinator_config = struct
  type config =
    { snark_coordinator_key : string
    ; snark_worker_fee : string
    ; work_selection : string
    ; worker_nodes : Snark_worker_config.t list
    ; base_config : Base_node_config.t
    }
  [@@deriving to_yojson]

  type t =
    { service_name : string
    ; config : config
    ; docker_config : Dockerfile.Service.t
    }
  [@@deriving to_yojson]

  let snark_coordinator_default_env ~snark_coordinator_key ~snark_worker_fee
      ~work_selection =
    [ ("MINA_SNARK_KEY", snark_coordinator_key)
    ; ("MINA_SNARK_FEE", snark_worker_fee)
    ; ("WORK_SELECTION", work_selection)
    ; ("MINA_CLIENT_TRUSTLIST", "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16")
    ]

  let create_cmd config =
    let base_args = Base_node_config.to_list config.base_config in
    let snark_coordinator_args =
      [ "daemon"
      ; "-run-snark-coordinator"
      ; config.snark_coordinator_key
      ; "-snark-worker-fee"
      ; config.snark_worker_fee
      ; "-work-selection"
      ; config.work_selection
      ]
    in
    List.concat [ snark_coordinator_args; base_args ]

  let create_docker_config ~image ~entrypoint ~ports ~volumes ~environment
      ~config =
    { Dockerfile.Service.image
    ; command = create_cmd config
    ; entrypoint
    ; ports
    ; environment
    ; volumes
    }

  let create ~service_name ~image ~ports ~volumes ~config =
    let entrypoint = Some [ "/root/entrypoint.sh" ] in
    let environment =
      snark_coordinator_default_env
        ~snark_coordinator_key:config.snark_coordinator_key
        ~snark_worker_fee:config.snark_worker_fee
        ~work_selection:config.work_selection
      @ Base_node_config.to_docker_env_vars config.base_config
    in
    let docker_config =
      create_docker_config ~image ~ports ~volumes ~environment ~entrypoint
        ~config
    in
    { service_name; config; docker_config }
end

module Postgres_config = struct
  type config =
    { host : string
    ; username : string
    ; password : string
    ; database : string
    ; port : int
    }
  [@@deriving to_yojson]

  type t =
    { service_name : string
    ; config : config
    ; docker_config : Dockerfile.Service.t
    }
  [@@deriving to_yojson]

  let postgres_image = "postgres:15-bullseye"

  let postgres_script =
    ( "postgres_entrypoint.sh"
    , {|#!/bin/bash
# This file is auto-generated by the local integration test framework.
# Create the archive database and import the schema
psql -U postgres -d archive -f ./create_schema.sql
|}
    )

  let postgres_create_schema_volume : Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "create_schema.sql"
    ; target = "/create_schema.sql"
    }

  let postgres_zkapp_schema_volume : Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "zkapp_tables.sql"
    ; target = "/zkapp_tables.sql"
    }

  let postgres_entrypoint_volume : Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "postgres_entrypoint.sh"
    ; target = "/docker-entrypoint-initdb.d/postgres_entrypoint.sh"
    }

  let postgres_default_envs ~username ~password ~database ~port =
    [ ("POSTGRES_USER", username)
    ; ("POSTGRES_PASSWORD", password)
    ; ("POSTGRES_DB", database)
    ; ("PGPASSWORD", password)
    ; ("POSTGRESQL_PORT_NUMBER", port)
    ]

  let create_connection_uri ~host ~username ~password ~database ~port =
    Printf.sprintf "postgres://%s:%s@%s:%d/%s" username password host port
      database

  let to_connection_uri t =
    create_connection_uri ~host:t.host ~port:t.port ~username:t.username
      ~password:t.password ~database:t.database

  let create_docker_config ~image ~entrypoint ~ports ~volumes ~environment =
    { Dockerfile.Service.image
    ; command = []
    ; entrypoint
    ; ports
    ; environment
    ; volumes
    }

  let create ~service_name ~image ~ports ~volumes ~config =
    let environment =
      postgres_default_envs ~username:config.username ~password:config.password
        ~database:config.database
        ~port:(Int.to_string config.port)
    in
    let docker_config =
      create_docker_config ~image ~ports ~volumes ~environment ~entrypoint:None
    in
    { service_name; config; docker_config }
end

module Archive_node_config = struct
  type config =
    { postgres_config : Postgres_config.t
    ; server_port : int
    ; base_config : Base_node_config.t
    }
  [@@deriving to_yojson]

  type t =
    { service_name : string
    ; config : config
    ; docker_config : Dockerfile.Service.t
    }
  [@@deriving to_yojson]

  let archive_entrypoint_script =
    ( "archive_entrypoint.sh"
    , {|#!/bin/bash
  # This file is auto-generated by the local integration test framework.
  # Sleep for 15 seconds
  echo "Sleeping for 15 seconds before starting..."
  sleep 15
  exec "$@"|}
    )

  let archive_entrypoint_volume : Docker_compose.Dockerfile.Service.Volume.t =
    { type_ = "bind"
    ; source = "archive_entrypoint.sh"
    ; target = Base_node_config.container_entrypoint_path
    }

  let create_cmd config =
    let base_args =
      [ "mina-archive"
      ; "run"
      ; "-postgres-uri"
      ; Postgres_config.to_connection_uri config.postgres_config.config
      ; "-server-port"
      ; Int.to_string config.server_port
      ]
    in
    let runtime_config_path =
      match config.base_config.runtime_config_path with
      | Some path ->
          [ "-config-file"; path ]
      | None ->
          []
    in
    List.concat [ base_args; runtime_config_path ]

  let create_docker_config ~image ~entrypoint ~ports ~volumes ~environment
      ~config =
    { Dockerfile.Service.image
    ; command = create_cmd config
    ; entrypoint
    ; ports
    ; environment
    ; volumes
    }

  let create ~service_name ~image ~ports ~volumes ~config =
    let entrypoint = Some [ "/root/entrypoint.sh" ] in
    let environment = Base_node_config.to_docker_env_vars config.base_config in
    let docker_config =
      create_docker_config ~image ~ports ~volumes ~environment ~entrypoint
        ~config
    in
    { service_name; config; docker_config }
end
