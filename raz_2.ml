(* 
Matthew A. Hammer (matthew.hammer@colorado.edu).

This is an implementation of the Random Access Zipper (RAZ).  It is
closely based on the OCaml implementation by Kyle Headley, and the
2016 article by Headley and Hammer.

There are some differences with the earlier version:

- This RAZ version places levels, not elements, at the center of the
  zipper's cursor.  It enjoys the invariant that #elements = #levels
  + 1, where #levels >= 1, and #elements >= 0. 

  The chief consequence of this representation is that it captures
  empty sequences with zero elements; the prior version required
  special sentinel elements at the ends to represent an empty
  sequence.  Here, we implement sentinels with levels, not special
  sequence elements.

- This RAZ version uses the OCaml type system to attempt to enforce
  some structural invariants about the presence of levels and trees in
  the zipper.  In particular: 

    * The types enforce that #levels = #elements + 1, across all of
      the Cons cells of the zipper, and its centered cursor level.

    * The types enforce that levels and elements interleave, and that
      a level follows each element, which can play the role of the
      "sentinel" if this element is the last/first one in the
      sequence.

  Note that this enforcement does not cover the invariants for trees,
  only the center of the zipper and its Cons cells.  Perhaps future
  verisons can use refinement types (or stronger dependent types) to
  capture the invariants over trees and tree lists. (Not all of these
  invariants are apparent to me yet).

- We assume, but do not statically enforce, that the unfocused tree
  also has that #levels = #elements + 1.  More work is needed to see
  how focus/unfocus/trim connect the invariant about the full tree to
  that of the trimmed subtrees.

- This version of the RAZ is a little shorter than the prior one:
  The Raz module body consists of ~120 lines 
  (not counting these comments or the module type RAZ).

- Unlike the earlier version, this one is untested / unmeasured. (!)

 *)

module type RAZ = 
  sig
    type 'a tree
    type 'a zip
    type lev    = int
    type dir    = L | R
    type 'a cmd (*[X]*) =
      | Insert  of dir * 'a * lev (*[X]*)
      | Remove  of dir
      | Replace of dir * 'a
      | Move    of dir
		     
    val empty  : lev(*[X]*) -> 'a zip (*[X;0]*)

    val elm_cnt : 'a tree -> int

    val do_cmd : 'a cmd (*[X1]*) -> 'a zip (*[X2;Y]*) -> 'a zip (*[X1*X2;M(X1)*Y]*)   (* <<< M~X1 is written, but not Y *) 
				      
    val unfocus : 'a zip (*[X;Y]*) -> 'a tree (*[X;M(X)*Y]*)        (* <<< M(X) is written (where M is namespace); Y is not *written*, it is reused. *)

    val focus   : 'a tree (*[X;Y]*) -> int -> 'a zip (*[X;M(X)*Y]*)   (* <<< "" *)


    (* For debugging and regression testing: Tests that the unfocused tree is well-formed. *)
    val wf_unfocused_tree : 'a tree -> bool

    (* For debugging and regression testing. *)
    val pp_zip : 
      (Format.formatter -> 'a -> Ppx_deriving_runtime.unit) ->
      Format.formatter -> 'a zip -> Ppx_deriving_runtime.unit

    (* For debugging and regression testing. *)
    val pp_tree : 
      (Format.formatter -> 'a -> Ppx_deriving_runtime.unit) ->
      Format.formatter -> 'a tree -> Ppx_deriving_runtime.unit

  end

module Raz : RAZ = struct
  type lev      = int
  [@@deriving show]
  type cnt      = int
  [@@deriving show]
  type dir      = L | R
  [@@deriving show]
  type bin_info = { lev:lev; elm_cnt:cnt }
  [@@deriving show]
  type 'a tree  = Bin  of bin_info * 'a tree * 'a tree (* Invariant: Levels of sub-trees are less-or-than-equal-to Bin's level *)
		| Leaf of 'a (* Invariant: There are N+1 Bin nodes in every tree with N leaves. *)
		| Nil (* Unfocused invariant: Exactly two Nils, the leftmost/rightmost terminals of the (unfocused) tree. *)
  [@@deriving show]
  type 'a elms  = Cons of 'a * lev * 'a elms (* Invariant: element always followed by a level *)
		| Trees of ('a tree) list    (* Invariant: trees not interposed with elements/levels. trim transforms this list. *)
  [@@deriving show]
  type 'a zip   = { left:'a elms; lev:lev; right:'a elms}
  [@@deriving show]

  module Wf = struct
    (* The Wf module consists of predicates for testing the
     well-formedness of the zipper and unfocused tree.  These
     predicates hold iff the invariants hold.

    Invariant 1: 
       Nils are permitted only at the endpoints of the
    unfocused tree representation.  Further, they *must* be there.  If
    they are not— if the endpoints consist of a Leaf, with a sequence
    element— then the invariant is broken that the sequence starts and
    ends with levels, the thing on which we are permitted to place the
    focus.

    Invariant 1 discussion:

    To see the importance of invariant 1, suppose that it is broken,
    and the endpoints are Leafs (sequence elements).  Now, we cannot
    ever place the focus earlier or later, to insert an element at the
    start or end, respectively.  This is because we choose to focus on
    levels, not sequence elements.

    Aside: Suppose now that we focus on sequence elements, not levels.
    Now we cannot easily represent an empty, focused sequence, since
    the focus is placed on an element, making the sequence non-empty.

    - - - - - - - - - - - - - 

    TODO: Capture the level-related invariants (\dagger).
    TODO: Capture the invariants about the zipper (\dagger\dagger).

    \dagger: Currently, we only capture the other structural
    invariants about where Nils are permitted, and thus, about the
    alternation of sequence elements and levels.

    \daggar\dagger: Currently, we only capture the invariants about
    the unfocused tree.  There should be invariants about the list of
    trees in the zipper as well (regarding where Nils are permitted).

     *)

  (* The tree_dir_op invariant is inductive, over the structure of the tree.

    Beyond the tree, it is parameterized by an optional direction,
    which can take on one of three possible values.  The value of
    this dir option parameter affects where Nils are permitted in the tree:

    (dir_op = Some L) means: There *must* be a Nil at the left-most position 
    (dir_op = Some R) means: There *must* be a Nil at the right-most position
    (dir_op = None)   means: There *must not* be a Nil anywhere within the tree.
   *)
	
  let rec tree_dir_op dir_op t =
    match dir_op, t with
    | None    , Nil              -> false (* Broken invariant: *)
    | Some _  , Leaf _           -> false (* Broken invariant: *)
    | Some _  , Nil              -> true
    | None    , Leaf _           -> true
    | (Some L), Bin(_, Nil, r  ) -> tree_dir_op None r
    | (Some R), Bin(_,  l, Nil ) -> tree_dir_op None l
    | None    , Bin(_,  l,  r  ) -> (tree_dir_op None l)     && (tree_dir_op None     r)
    | (Some L), Bin(_,  l,  r  ) -> (tree_dir_op (Some L) l) && (tree_dir_op None     r)
    | (Some R), Bin(_,  l,  r  ) -> (tree_dir_op None l)     && (tree_dir_op (Some R) r)

  let tree t =
    match t with
    | Nil          -> false (* Broken invariant: #levels = #leaves + 1 *)
    | Leaf _       -> false (* Broken invariant: #levels = #leaves + 1 *)
    | Bin(_, l, r) -> (tree_dir_op (Some L) l) && (tree_dir_op (Some R) r)
  end
		
  let wf_unfocused_tree = Wf.tree

  let empty (l:lev(*[X]*)) : 'a zip(*[X;0]*) = 
    {left=Trees([]);lev=l;right=Trees([])}
      
  let tree_of_lev (l:lev(*[X]*)) : 'a tree(*[X;0]*) = 
    Bin({lev=l;elm_cnt=0},Nil,Nil)
       
  let elm_cnt_of_tree (t:'a tree) : cnt = 
    match t with
    | Bin(bi,_,_) -> bi.elm_cnt
    | Leaf(_)     -> 1
    | Nil         -> 0
	
  let elm_cnt t = elm_cnt_of_tree t
	       
  let trim (d:dir) (t:'a elms(*[X1*X2;Y]*)) : ('a * lev(*[X1]*) * 'a elms(*[X2;Y]*)) option =
    match t with
    | Cons(a, lev, elms) -> Some((a, lev, elms))
    | Trees(trees) -> 
       let rec loop (ts:('a tree(*[X3;Y3]*)) list) (st:'a option) : ('a * lev(*[X4]*) * 'a elms(*[X3*X4;Y3]*)) option =
	 match ts, st with
	 | [],                       _      -> None
	 | Nil::trees,               _      -> loop trees st
	 | Leaf(x)::trees,           None   -> loop trees (Some x)
	 | Leaf(_)::_,               Some _ -> failwith "illegal argument: trim: leaf-leaf" (* leaf-leaf case: Violates Invariant that elements and levels interleave. *)
	 | Bin(bi, Nil, Nil)::trees, Some x -> Some(x, bi.lev, Trees(trees))
	 | Bin(bi, l, r)::trees, _          ->
	    match d with L -> loop (l::(tree_of_lev bi.lev :: r :: trees)) st 
		       | R -> loop (r::(tree_of_lev bi.lev :: l :: trees)) st
       in loop trees None
	       
  type 'a cmd =
    | Insert  of dir * 'a * lev
    | Remove  of dir
    | Replace of dir * 'a
    | Move    of dir
  type 'a cmds = 'a zip -> 'a zip
				  
  let do_cmd : 'a cmd -> 'a cmds =
    function
    | Insert (d,a,lev) -> (
      match d with
      | L -> fun z -> {z with left  = Cons(a, lev, z.left )}
      | R -> fun z -> {z with right = Cons(a, lev, z.right)}
    )
    | ( Remove (d) | Replace(d,_) | Move (d) ) as trim_cmd -> (
      fun z ->
      let trimmed = match d with
	| L -> trim L z.left
	| R -> trim L z.right
      in
      match trimmed with
      | None -> z (* do nothing; nothing to remove/replace/move *)
      | Some((elm, lev, rest)) -> (
	match trim_cmd with
	| Insert _ -> failwith "impossible" (* Already handled, above. *)
	| Remove(_) ->
	   (match d with L -> {z with left =rest}  (* Removes elm and lev. *)
		       | R -> {z with right=rest}) (* Removes elm and lev. *)
	| Replace(_, a) ->
	   (match d with L -> {z with left =Cons(a, lev, rest)}  (* Replaces elm with a. *)
		       | R -> {z with right=Cons(a, lev, rest)}) (* Replaces elm with a. *)
	| Move(_) ->
	   (match d with L -> {left =rest; lev=lev; right=Cons(elm,z.lev,z.right)}
		       | R -> {right=rest; lev=lev; left =Cons(elm,z.lev,z.left )})))
								
  let rec append (t1:'a tree (*[X1;Y1]*)) (t2:'a tree(*[X2;Y2]*)) : 'a tree(*[X1*X2;M(X1*X2)*(Y1*Y2)]*) =
    let elm_cnt = (elm_cnt_of_tree t1) + (elm_cnt_of_tree t2) in
    match t1, t2 with
    | Nil, _ -> t2
    | _, Nil -> t1
    | Leaf(_), Leaf(_)       -> failwith "invalid argument: append: leaf-leaf" (* leaf-leaf case: Violates invariant that elements and levels interleave. *)
    | Leaf(a), Bin(bi, l, r) -> Bin ({lev=bi.lev;elm_cnt=elm_cnt}, append t1 l, r)
    | Bin(bi, l, r), Leaf(a) -> Bin ({lev=bi.lev;elm_cnt=elm_cnt}, l, append r t2)
    | Bin(bi1, l1, r1),
      Bin(bi2, l2, r2) -> if bi1.lev >= bi2.lev
			  then Bin ({lev=bi1.lev;elm_cnt=elm_cnt}, l1, append r1 t2)
			  else Bin ({lev=bi2.lev;elm_cnt=elm_cnt}, append t1 l2, r2)
				  
  let rec tree_of_trees (d:dir) (tree:'a tree) (trees:('a tree(*[X2;Y2]*))list(*[;]*)) : 'a tree (*[X1*X2;M(X1*X2)*(Y1*Y2)]*) =
    match trees with
    | [] -> tree
    | tree2::trees -> match d with (* Grown proceeds in direction `d`: either leftward (L) or rightward (R) *)
		      | L -> tree_of_trees d (append tree2 tree) trees
		      | R -> tree_of_trees d (append tree tree2) trees
			    
  let rec tree_of_elms (d:dir) (elms:'a elms) : 'a tree =
    match elms with (* Grown proceeds in direction `d`: either leftward (L) or rightward (R) *)
    | Trees(trees) -> tree_of_trees d Nil trees
    | Cons(elm,lev,elms) -> (match d with
			     | L -> append (tree_of_elms L elms) (append (tree_of_lev lev) (Leaf elm))
			     | R -> append (append (Leaf elm) (tree_of_lev lev)) (tree_of_elms R elms)
			    )
			   
  let unfocus (z: 'a zip) : 'a tree =      
    append 
      (tree_of_elms L z.left) 
      (append (tree_of_lev z.lev)
	      (tree_of_elms R z.right))
	   
  let focus (tree:'a tree) (pos:int) : 'a zip =  
    (* Input sanitization: Force position to be defined within the tree, in range [0, elm-count(tree)]. *)
    let pos = let n = elm_cnt_of_tree tree in 
	      if pos > n then n else if pos < 0 then 0 else pos
    in
    (* Loop, walking down the tree to find the unique position with pos number of elements to the left. *)
    let rec loop (pos:int) (tree:'a tree) (tsl:('a tree) list) (tsr:('a tree) list) =
      match tree with
      | Nil     -> failwith "invalid argument: focus: nil"  (* Violates: #Bins = #Leaves + 1 *)
      | Leaf(x) -> failwith "invalid argument: focus: leaf" (* Violates: #Bins = #Leaves + 1 *)
      | Bin(bi,l,r) -> (
	let cl = elm_cnt_of_tree l in
	if pos = cl then {lev=bi.lev; left=Trees(l::tsl); right=Trees(r::tsr)}
	else if pos < cl then loop pos      l tsl (Bin({lev=bi.lev; elm_cnt=elm_cnt_of_tree r},Nil,r)::tsr)
	else                  loop (pos-cl) r     (Bin({lev=bi.lev; elm_cnt=cl               },l,Nil)::tsl) tsr
      )
    in loop pos tree [] []
end
		     
(* 

Count valid instances, for small sizes 0, 1, ..:
 levels   a,b,c, ...
 elements x,y,z, ...

Size 0: 
 Seq:    a
 #Trees: 1
 Tree:   Bin(a, Nil, Nil)

Size 1: 
 Seq:    a x b
 #Trees: 1 + 1 = 2

 Tree 1: Bin(b, Bin(a, Nil, Leaf(x)), Nil)
 Tree 2: Bin(a, Nil, Bin(b, Leaf(x), Nil))

Size 2: 
 Seq:    a x b y c
 #Trees: 2 + 1 + 2 = 5

Size 3:
 Seq:    a x b y c z d
 #Trees  5 + 2 + 2 + 5 = 13 

  x    0 1 2 3 4 5 6
Fib x  1 1 2 3 5 8 13
Fib 2x 1 2 5 13
*)
