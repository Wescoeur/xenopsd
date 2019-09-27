open Topology

module D = Debug.Make (struct
  let name = "test_topology"
end)

let make_numa ~numa ~sockets ~cores =
  let distances =
    Array.init numa (fun i ->
        Array.init numa (fun j ->
            if i = j then 10 else 10 + (11 * abs (j - i))))
  in
  let cores_per_numa = cores / numa in
  let cpu_to_node = Array.init cores (fun core -> core / cores_per_numa) in
  NUMA.v ~distances ~cpu_to_node

let make_numa_assymetric ~cores_per_numa =
  (* e.g. AMD Opteron 6272 *)
  let numa = 8 in
  let distances =
    [| [|10; 16; 16; 22; 16; 22; 16; 22|]
     ; [|16; 10; 22; 16; 16; 22; 22; 17|]
     ; [|16; 22; 10; 16; 16; 16; 16; 16|]
     ; [|22; 16; 16; 10; 16; 16; 22; 22|]
     ; [|16; 16; 16; 16; 10; 16; 16; 22|]
     ; [|22; 22; 16; 16; 16; 10; 22; 16|]
     ; [|16; 22; 16; 22; 16; 22; 10; 16|]
     ; [|22; 16; 16; 22; 22; 16; 16; 10|] |]
  in
  let cpu_to_node =
    Array.init (cores_per_numa * numa) (fun core -> core / cores_per_numa)
  in
  NUMA.v ~distances ~cpu_to_node

type t = {worst: int; average: float; bandwidth: float; best: int}

let pp =
  Fmt.(
    Dump.record
      [ Dump.field "worst" (fun t -> t.worst) int
      ; Dump.field "average" (fun t -> t.average) float
      ; Dump.field "bandwidth" (fun t -> t.bandwidth) float
      ; Dump.field "best" (fun t -> t.best) int ])

let sum_costs l =
  D.debug "====" ;
  List.fold_left
    (fun accum cost ->
      D.debug "bandwidth += %f" cost.bandwidth ;
      { worst= max accum.worst cost.worst
      ; average= accum.average +. cost.average
      ; bandwidth= accum.bandwidth +. cost.bandwidth
      ; best= min accum.best cost.best })
    {worst= min_int; average= 0.; bandwidth= 0.; best= max_int}
    l

let vm_access_costs host all_vms (vcpus, nodes, cpuset) =
  let all_vms = ((vcpus, nodes), cpuset) :: all_vms in
  let n = List.length nodes in
  let slice_of vcpus cpuset = float vcpus /. float (CPUSet.cardinal cpuset) in
  (* a simple model with a single interconnect;
   * assuming all non-local accesses go through it *)
  let interconnect_slice_of ((_, nodes), cpuset) =
    (* percentage of time that an access is a remote access *)
    let n = List.length nodes in
    let remote_percentage = float (n - 1) /. float n in
    remote_percentage *. float (CPUSet.cardinal cpuset)
  in
  let all_interconnect_slices =
    all_vms |> List.map interconnect_slice_of |> List.fold_left ( +. ) 0.
  in
  let want_slice = slice_of vcpus cpuset in
  let used_cpus =
    all_vms |> List.map snd |> List.fold_left CPUSet.union CPUSet.empty
  in
  let costs =
    cpuset |> CPUSet.elements
    |> List.map (fun c ->
           let distances =
             List.map
               (fun node ->
                 let d = NUMA.distance host (NUMA.node_of_cpu host c) node in
                 let (NUMA.Node nodei) = node in
                 D.debug "CPU %d <-> Node %d distance: %d" c nodei d ;
                 d)
               nodes
           in
           D.debug "Distances: %s"
             (List.map string_of_int distances |> String.concat ",") ;
           let worst = List.fold_left max 0 distances in
           let best = List.fold_left min max_int distances in
           let average = float (List.fold_left ( + ) 0 distances) /. float n in
           (* if all VMs run their CPUs 100% in the recommended soft affinity
            * how many time slices can this vCPU get?
            * *)
           D.debug "--" ;
           let all_slices =
             List.fold_left
               (fun acc ((vcpus, _), cpuset) ->
                 D.debug "CPU %d; CPUSet: %s; slice: %f" c
                   (Fmt.to_to_string CPUSet.pp_dump cpuset)
                   (slice_of vcpus cpuset) ;
                 if CPUSet.mem c cpuset then acc +. slice_of vcpus cpuset
                 else acc)
               0. all_vms
           in
           let cpu_slice = want_slice /. all_slices in
           D.debug "cpu_slice: %f out of %f" want_slice all_slices ;
           assert (want_slice <= all_slices) ;
           (* if all CPUs in this NUMA node are busy accessing local memory;
            * how much of that bandwidth can this cpu get? *)
           let numa_local_slice =
             1.
             /. float
                  ( CPUSet.inter
                      (NUMA.cpuset_of_node host (NUMA.node_of_cpu host c))
                      used_cpus
                  |> CPUSet.cardinal )
           in
           (* we got N nodes; the local node is accessed only 1/N times *)
           let numa_local_slice =
             numa_local_slice /. float (List.length nodes)
           in
           D.debug "NUMA local slice: %f" numa_local_slice ;
           let numa_remote_slice =
             let my_slice =
               interconnect_slice_of (((), nodes), CPUSet.singleton c)
             in
             if my_slice <> 0. then my_slice /. all_interconnect_slices else 0.
           in
           D.debug "NUMA remote slice: %f" numa_remote_slice ;
           (* assume interconnect has half bandwidth of local node *)
           let bandwidth =
             cpu_slice *. (numa_local_slice +. (numa_remote_slice /. 2.))
           in
           D.debug "bandwidth: %f" bandwidth ;
           {worst; best; bandwidth; average})
    |> sum_costs
  in
  D.debug "Costs: %s" (Fmt.to_to_string pp costs) ;
  let cpus = float @@ CPUSet.cardinal cpuset in
  { costs with
    average= costs.average /. cpus
  ; bandwidth= costs.bandwidth *. slice_of vcpus cpuset }

let cost_not_worse ~default c =
  let worst = max default.worst c.worst in
  let best = min default.best c.best in
  let average = min default.average c.average in
  D.debug "Default access times: %s; New plan: %s"
    (Fmt.to_to_string pp default)
    (Fmt.to_to_string pp c) ;
  Alcotest.(
    check int "The worst-case access time should not be changed from default"
      default.worst worst) ;
  Alcotest.(check int "Best case access time should not change" best c.best) ;
  Alcotest.(
    check (float 1e-3) "Average access times could improve" average c.average) ;
  if c.best < default.best then
    D.debug "The new plan has improved the best-case access time!" ;
  if c.worst < default.worst then
    D.debug "The new plan has improved the worst-case access time!" ;
  if c.average < default.average then
    D.debug "The new plan has improved the average access time!"

let check_aggregate_costs_not_worse (default, next, _) =
  let default = sum_costs default in
  let next = sum_costs next in
  cost_not_worse ~default next ;
  let bandwidth = max default.bandwidth next.bandwidth in
  Alcotest.(
    check (float 1e-3) "Bandwidth could improve" bandwidth next.bandwidth) ;
  if next.bandwidth > default.bandwidth then D.debug "Bandwidth has improved!"

let test_allocate ?(mem = Int64.shift_left 1L 30) h ~vms () =
  let memsize = Int64.shift_left 1L 34 in
  let nodea = Array.init (NUMA.nodes h |> List.length) (fun _ -> memsize) in
  D.debug "NUMA: %s" (Fmt.to_to_string NUMA.pp_dump h) ;
  let cores = NUMA.all_cpus h |> CPUSet.cardinal in
  let vm_cores = max 2 (cores / vms) in
  List.init vms (fun i -> i + 1)
  |> List.fold_left
       (fun (costs_old, costs_new, plans) i ->
         D.debug "Planning VM %d" i ;
         let affinity = CPUSet.all cores in
         let vm = NUMAResource.v ~memory:mem ~vcpus:vm_cores ~affinity in
         let nodes =
           List.mapi
             (fun i n -> (n, NUMA.resource h n ~memory:nodea.(i)))
             (NUMA.nodes h)
         in
         match Topology.plan h nodes ~vm with
         | None ->
             Alcotest.fail "No NUMA plan"
         | Some plan ->
             D.debug "NUMA allocation succeeded for VM %d: %s" i
               (Fmt.to_to_string CPUSet.pp_dump plan) ;
             let usednodes =
               plan |> CPUSet.elements
               |> List.map (NUMA.node_of_cpu h)
               |> List.sort_uniq compare
             in
             let available_mem =
               usednodes
               |> List.map (fun (NUMA.Node i) -> nodea.(i))
               |> List.fold_left Int64.add 0L
             in
             Alcotest.(
               check int64 "Enough memory available on selected nodes" mem
                 (min available_mem mem)) ;
             let rec allocate mem =
               let mem_try =
                 Int64.div mem (List.length usednodes |> Int64.of_int)
               in
               D.debug "mem_try: %Ld" mem_try ;
               if mem_try > 0L then
                 let mem_allocated =
                   List.fold_left
                     (fun mem n ->
                       let (NUMA.Node idx) = n in
                       let memfree = max 0L (Int64.sub nodea.(idx) mem_try) in
                       let delta = Int64.sub nodea.(idx) memfree in
                       nodea.(idx) <- memfree ; Int64.add mem delta)
                     0L usednodes
                 in
                 allocate @@ Int64.sub mem mem_allocated
             in
             allocate mem ;
             let costs_numa_aware =
               vm_access_costs h plans (vm_cores, usednodes, plan)
             in
             let costs_default =
               vm_access_costs h plans
                 (vm_cores, List.map fst nodes, NUMA.all_cpus h)
             in
             cost_not_worse ~default:costs_default costs_numa_aware ;
             ( costs_default :: costs_old
             , costs_numa_aware :: costs_new
             , ((vm_cores, usednodes), plan) :: plans ))
       ([], [], [])
  |> check_aggregate_costs_not_worse

let mem3 = Int64.div (Int64.mul 4L (Int64.shift_left 1L 34)) 3L

let suite =
  ( "topology test"
  , [ ( "Allocation of 1 VM on 1 node"
      , `Quick
      , test_allocate ~vms:1 @@ make_numa ~numa:1 ~sockets:1 ~cores:2 )
    ; ( "Allocation of 10 VMs on 1 node"
      , `Quick
      , test_allocate ~vms:10 @@ make_numa ~numa:1 ~sockets:1 ~cores:8 )
    ; ( "Allocation of 1 VM on 2 nodes"
      , `Quick
      , test_allocate ~vms:1 @@ make_numa ~numa:2 ~sockets:2 ~cores:4 )
    ; ( "Allocation of 10 VM on 2 nodes"
      , `Quick
      , test_allocate ~vms:10 @@ make_numa ~numa:2 ~sockets:2 ~cores:4 )
    ; ( "Allocation of 1 VM on 4 nodes"
      , `Quick
      , test_allocate ~vms:1 @@ make_numa ~numa:4 ~sockets:2 ~cores:16 )
    ; ( "Allocation of 10 VM on 4 nodes"
      , `Quick
      , test_allocate ~vms:10 @@ make_numa ~numa:4 ~sockets:2 ~cores:16 )
    ; ( "Allocation of 10 VM on assymetric nodes"
      , `Quick
      , test_allocate ~vms:10 (make_numa_assymetric ~cores_per_numa:4) )
    ; ( "Allocation of 10 VM on assymetric nodes"
      , `Quick
      , test_allocate ~vms:6 ~mem:mem3 (make_numa_assymetric ~cores_per_numa:4)
      ) ] )
