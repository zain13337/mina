open Core_kernel

[%%versioned
module Stable = struct
  module V1 = struct
    type t = Pow_2_roots_of_unity of int
    [@@deriving sexp, eq, compare, hash, yojson]

    let to_latest = Fn.id
  end
end]

[%%define_locally
Stable.Latest.(equal)]

let log2_size (Pow_2_roots_of_unity k) = k

let size t = 1 lsl log2_size t
