(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Account_balance_request.t : An AccountBalanceRequest is utilized to make a balance request on the /account/balance endpoint. If the block_identifier is populated, a historical balance query should be performed. 
 *)

type t =
  { network_identifier : Network_identifier.t
  ; account_identifier : Account_identifier.t
  ; block_identifier : Partial_block_identifier.t option [@default None]
  ; (* In some cases, the caller may not want to retrieve all available balances for an AccountIdentifier. If the currencies field is populated, only balances for the specified currencies will be returned. If not populated, all available balances will be returned.  *)
    currencies : Currency.t list [@default []]
  }
[@@deriving yojson { strict = false }, show, eq]

(** An AccountBalanceRequest is utilized to make a balance request on the /account/balance endpoint. If the block_identifier is populated, a historical balance query should be performed.  *)
let create (network_identifier : Network_identifier.t)
    (account_identifier : Account_identifier.t) : t =
  { network_identifier
  ; account_identifier
  ; block_identifier = None
  ; currencies = []
  }
