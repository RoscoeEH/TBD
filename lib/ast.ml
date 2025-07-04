(*
 * The idea is that the AST should contain all the structural info,
 * but while building it from the cst, we do arity and type checking,
 * and associate variable references to slots in binding scopes.
 *)

open Result
open List
open Array

(* monad sig for result *)
module RM = struct
  type e
  type 'a t = ('a, e) result

  let bind a f = match a with
    | Error e -> Error e
    | Ok v -> f v

  let (>>=) = bind
  let return a = Ok a

  let map f a = match a with
    | Error e -> Error e
    | Ok v -> Ok (f v)
  let (>>|) a f = map f a

  let (<|>) a b = match a with
    | Ok a -> Ok a
    | Error _ -> b
  let (>>) a b = match a with
    | Error e -> Error e
    | Ok _ -> b

  let (let*) a f = bind a f

  let map_err f a = match a with
    | Ok v -> Ok v
    | Error e -> Error (f e)
end
open RM

type name = string

type type_t =
| Int_t
| Fun_t of type_t * type_t

(* TODO consider merging v_ref and binding, so that every name+type
   also has a slot idx *)
type binding = {
    b_name : name;
    b_tp : type_t;
  }
and v_ref = {
    v_name : name;
    v_slot: int;
  }
and func = {
    f_args : binding Array.t;
    captures : (binding * int) Array.t;
    f_body : expr
  }
and let_block = {
    binds : (binding * expr) Array.t;
    l_body : expr
  }
and application = {
    func : expr;
    a_args : expr Array.t
    (* TODO we need to distinguish between partial and total
     * application, aka are all the required arguments present. We
     * can't do that currently, since a function that returns a
     * function is a valid type, but a partially applied function of
     * two arguments is also typed as a curried function.
     *
     * See:
https://www.cambridge.org/core/journals/journal-of-functional-programming/article/making-a-fast-curry-pushenter-vs-evalapply-for-higherorder-languages/02447DB613E94DC35ACDCB24DB39F085
     *
     * I don't think we want to support partial application at the
     * moment, since it requires complexity in the runtime I don't
     * want to deal with currently. The issue is that there isn't really
     * a good place to insert the check that each application is total
     * and not partial. This is mostly cause things like applying a
     * let block that returns a function to an arg is valid, so we have
     * the function type but not the number of arguments at the
     * application site.
     *
     * TODO we could adjust the types to be more expressive to distinguish
     * int -> int -> int and int -> (int -> int)
     * or we could find some place where we can check this property
     * and fail on partial applications. I'd like to do the second if
     * possible since in the longer term partial application is
     * something we will want, and it seems annoying to change it
     * just to change it back later.
     *
     * At the moment we are going to use something similar to the push
     * model.
     *)
  }
and literal = {
    value : int
  }
and content =
    | Fun of func
    | Let of let_block
    | Var of v_ref
    | App of application
    | Lit of literal
and expr = {
  tp: type_t;
  inner: content
}

(* simple lifts from cst to ast types *)
let from_cst_name = fun a -> a
let rec from_cst_type t = match t with
  | Cst.Int_t -> Int_t
  | Cst.Fun_t (hd, tl) -> Fun_t ((from_cst_type hd), (from_cst_type tl))
let from_cst_binding ((n, t) : Cst.binding) = { b_name = n ; b_tp = from_cst_type t; }

let matching_binding n (scope : binding array) =
  match find_index (fun b -> n == b.b_name) scope with
  | None -> None
  | Some idx -> Some (scope.(idx), idx)

(* fetch a binding from a scope, and return it along with some indexing info *)
let lookup_name name (scopes : binding array list) =
  let helper acc s = match acc with
    | Ok v -> Ok v
    | Error n -> (
        match matching_binding name s with
        | None -> Error (n+(Array.length s))
        | Some (b, i) -> Ok (b, n+i)
      )
  in
  let r = List.fold_left helper (Error 0) scopes in
  map_err (fun _ -> name ^ " not defined") r

(* Collects Ok values, stops on an Error *)
let sequence (lst: ('a, 'e) result list) =
  let cons_ok (elm: ('a, 'e) result) (acc: ('a list, 'e) result) =
    let* a = acc in
    let* e = elm in
    Ok (e :: a)
  in
  let (init: ('a list, 'e) result) = Ok [] in
  List.fold_right cons_ok lst init

(* TODO this is still not great but it it is better.
 *
 * It should probably return a result rather than panic.
 *
 * All the threading of the free_list makes a monad tempting but I'm
 * not sure how exactly to set it up tbh.
 *)
let rec from_cst (scopes : binding array list) (free_list : name list) (expr : Cst.expr) =
  match expr with
      | Cst.Lit v -> (free_list, { tp = Int_t; inner = Lit {value=v}})
      | Cst.Let (binds, body) ->
        let a_binds = of_list binds in
        let arms = Array.map (fun (_bind, expr) -> expr) a_binds in
        let binds' = Array.map (fun (b, _expr) -> from_cst_binding b) a_binds in
        let (fl2, body') = from_cst (binds' :: scopes) free_list body in
        let (fl3, arms') = lift_arms scopes fl2 arms in
        (fl3, { tp = body'.tp;
                inner = Let {
                    l_body = body';
                    binds = Array.combine binds' arms'}})
      | Cst.App (func, args) ->
        let (fl2, func') = from_cst scopes free_list func in
        (match check_app (func'.tp) scopes fl2 args with
         | Ok (fl3, args', a_t) ->
           (fl3, {tp=a_t; inner=App {func = func'; a_args = Array.of_list args'}})
         | Error s -> raise (Failure s))
      | Cst.Var name ->
        (match lookup_name (from_cst_name name) scopes with
           | Error s -> raise (Failure s)
           | Ok (bind, slot_idx) ->
             (free_list,
              {tp=bind.b_tp; inner=Var {v_name=name; v_slot=slot_idx}}))
      | Cst.Fun (args, body) ->
        let args' = Array.map from_cst_binding (Array.of_list args) in
        let (fl2, body') = from_cst [args'] [] body in
        let cap_list = List.map (fun n -> lookup_name n scopes) fl2 in
        (match sequence cap_list with
           | Error s -> raise (Failure s)
           | Ok captures ->
             let lifted_func = Fun {
                 f_args = args';
                 f_body = body';
                 captures = (Array.of_list captures);
               }
             in
             let func_t = Array.fold_right (fun arg tail_t -> Fun_t (arg.b_tp, tail_t)) args' body'.tp in
             (List.append free_list fl2, {tp=func_t; inner=lifted_func}))
and check_app f_t scopes fl exprs =
  (* checks arity + types, returns (freelist, lifted arg list, output type) or error*)
  match exprs with
  | [] -> Ok (fl, [], f_t)
  | arg :: arg_tail -> (match f_t with
      | Fun_t (a_t, r_t) ->
        let (fl2, arg') = from_cst scopes fl arg in
        if arg'.tp == a_t
        then (match check_app r_t scopes fl2 arg_tail with
            | Error s -> Error s
            | Ok (fl3, arg_tail', o_t) -> Ok (fl3, arg' :: arg_tail', o_t))
        else Error "Argument type doesn't match expected type from function"
      | _ -> Error "Too many arguments or non-function type in App head")
and lift_arms scopes fl arms =
    let helper fl2 arm = from_cst scopes fl2 arm in
    Array.fold_left_map helper fl arms
