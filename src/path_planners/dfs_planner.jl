module DFSPlanner

using Parameters
using LightGraphs
using DataStructures
using JLD2, FileIO
using CRCBS

using ..TaskGraphs

export
    DFSRoutePlanner

"""
    DFSRoutePlanner

Prioritized Depth-First Search route planner.
"""
@with_kw struct DFSRoutePlanner{C}
    logger::SolverLogger{C} = SolverLogger{C}()
end
function construct_heuristic_model(solver::DFSRoutePlanner,env_graph;
        ph = PerfectHeuristic(get_dist_matrix(env_graph)),
        kwargs...)
    construct_composite_heuristic(ph,ph,NullHeuristic())
end
function TaskGraphs.construct_cost_model(solver::DFSRoutePlanner,
        schedule, cache, problem_spec, env_graph;
        extra_T=400, primary_objective=SumOfMakeSpans(), kwargs...)
    cost_model = construct_composite_cost_model(
        typeof(primary_objective)(schedule,cache),
        FullCostModel(maximum,TravelTime()),
        FullCostModel(maximum,TravelDistance())
        )
    heuristic_model = construct_heuristic_model(solver,env_graph;kwargs...)
    # ph = PerfectHeuristic(get_dist_matrix(env_graph))
    # heuristic_model = construct_composite_heuristic(ph,ph,NullHeuristic())
    cost_model, heuristic_model
end

export
    sorted_actions,
    get_conflict_idx,
    select_action_dfs!,
    get_next_node_matching_agent_id,
    update_envs!,
    prioritized_dfs_search

@with_kw struct DFS_SearchState
    pickup_i::Int   = 0 # if i < start, iterate from current action (inclusive). Defines where to "pick back up"
    reset_i::Int    = 0 # if i > reset_i, iterate through all possible actions. Defines the point below which to "reset" the action vector
end
function update_search_state(s,i)
    s = DFS_SearchState(s,reset_i = max(s.reset_i,s.pickup_i+1))
    if s.pickup_i > i # reset pickup_i once it has been exceeded
        s = DFS_SearchState(s, pickup_i = 0)
    end
    if s.reset_i < i
       s = DFS_SearchState(s,reset_i = i)
    end
    s
end
function sorted_actions(env,s)
    f = (s,a,sp)->add_heuristic_cost(env,get_transition_cost(env,s,a,sp),get_heuristic_cost(env,sp))
    sort(
        collect(get_possible_actions(env,s)),
        by=a->f(s,a,get_next_state(env,s,a))
    )
end
function get_conflict_idx(envs,states,actions,i,ordering,idxs)
    idx = ordering[i]
    env = envs[idx]
    s = states[idx]
    a = actions[idx]
    sp = get_next_state(env,s,a)
    pi = PathNode(s,a,sp)
    for (j,idx) in enumerate(ordering[1:max(1,i-1)])
        if j == i
            continue
        end
        env = envs[idx]
        s = states[idx]
        a = actions[idx]
        sp = get_next_state(env,s,a)
        pj = PathNode(s,a,sp)
        if detect_state_conflict(pi,pj) || detect_action_conflict(pi,pj)
            return j
        end
    end
    return -1
end
function get_next_node_matching_agent_id(schedule,cache,agent_id)
    node_id = RobotID(agent_id)
    for v in cache.active_set
        if agent_id == get_path_spec(schedule, v).agent_id
            return get_vtx_id(schedule,v)
        end
    end
    return node_id
end
function update_planning_cache!(solver,env)
    cache = env.cache
    schedule = env.schedule
    while true
        done = true
        for v in collect(cache.active_set)
            if get_path_spec(schedule,v).plan_path==false
                path = Path{PCCBS.State,PCCBS.Action,get_cost_type(env.env)}(
                    s0=PCCBS.State(-1, -1),
                    cost=get_initial_cost(env.env)
                    )
                # update planning cache only
                update_planning_cache!(solver,env,v,path) # NOTE I think this is all we need, since there is no actual path to update
                done = false
            end
        end
        if done
            break
        end
    end
end
function update_envs!(solver,search_env,envs,paths)
    cache = search_env.cache
    schedule = search_env.schedule
    cbs_node = initialize_root_node(search_env)
    # update_planning_cache!(solver,search_env)        cache.tF[v] = get_final_state(path).t

    # update cache times
    up_to_date = true
    for i in 1:length(envs)
        env = envs[i]
        path = paths[i]
        v = get_vtx(schedule,env.node_id)
        s = get_final_state(path)
        t_arrival = max(cache.tF[v], s.t + get_distance(search_env.dist_function,s.vtx,env.goal.vtx))
        if is_goal(envs[i],s)
            if t_arrival > cache.tF[v] && env.goal.vtx != -1
                log_info(-1,solver,"DFS update_envs!(): extending tF[v] from $(cache.tF[v]) to $t_arrival in ",string(env.schedule_node),", s = ",string(s))
                cache.tF[v] = t_arrival
                up_to_date = false
            end
        end
    end
    # reset cache
    if !up_to_date
        t0,tF,slack,local_slack = process_schedule(schedule;t0=cache.t0,tF=cache.tF)
        cache.t0            .= t0
        cache.tF            .= tF
        cache.slack         .= slack
        cache.local_slack   .= local_slack
        # rebuild envs to reset goal time
        for i in 1:length(envs)
            env = envs[i]
            path = paths[i]
            v = get_vtx(schedule,env.node_id)
            envs[i],_ = build_env(solver,search_env,cbs_node,v)
        end
    end
    # mark finished envs as complete
    for i in 1:length(envs)
        env = envs[i]
        path = paths[i]
        if is_goal(envs[i],get_final_state(path))
            # update schedule and cache
            v = get_vtx(schedule,env.node_id)
            if !(v in cache.closed_set)
                update_planning_cache!(solver,search_env,v,path)
                @assert v in cache.closed_set
                @assert i == env.agent_idx
            end
        end
    end
    update_planning_cache!(solver,search_env)
    i = 0
    while i < length(envs)
        i += 1
        env = envs[i]
        path = paths[i]
        v = get_vtx(schedule,env.node_id)
        if is_goal(envs[i],get_final_state(path))
            # update schedule and cache
            if !(v in cache.closed_set)
                update_planning_cache!(solver,search_env,v,path)
                update_planning_cache!(solver,search_env)
            end
            @assert v in cache.closed_set
            @assert i == env.agent_idx
            for v2 in outneighbors(schedule,v)
                if get_path_spec(schedule,v).agent_id == i
                    if !(v2 in cache.active_set)
                        log_info(-1,solver.l2_verbosity,"node ",string(get_node_from_vtx(schedule,v2))," not yet in active set")
                        log_info(-1,solver.l2_verbosity,"inneighbors of ",string(get_node_from_vtx(schedule,v2))," are ",map(v3->string(get_node_from_vtx(schedule,v3)),neighborhood(schedule,v2,3,dir=:in))...)
                    end
                end
            end
            # swap out env for new env
            node_id = get_next_node_matching_agent_id(schedule,cache,env.agent_idx)
            @assert node_id != env.node_id
            if get_vtx(schedule,node_id) in cache.active_set
                envs[i],_ = build_env(solver,search_env,cbs_node,get_vtx(schedule,node_id))
                # i = 0
                i -= 1
            else
                node_string = string(get_node_from_id(search_env.schedule,node_id))
                log_info(4,solver,"cannot update environment for agent $i because next node ",node_string," not in cache.active_set")
            end
        end
    end
    update_cost_model!(search_env)
    envs,paths
end
function select_ordering(solver,search_env,envs)
    schedule = search_env.schedule
    cache = search_env.cache
    ordering = sort(
        collect(1:search_env.num_agents),
        by = i->(
            ~isa(envs[i].schedule_node,Union{COLLECT,DEPOSIT}),
            ~isa(envs[i].schedule_node,CARRY),
            minimum(cache.slack[get_vtx(schedule,envs[i].node_id)])
            )
        )
    log_info(4,solver,"ordering = $ordering")
    ordering
end
function select_action_dfs!(solver,envs,states,actions,i,ordering,idxs,search_state=SearchState())
    # search_states = map(e->search_state,1:length(envs)+1)
    # while true
    search_state = update_search_state(search_state,i)
    # search_states[i] = update_search_state(search_states[i],i)
    if i <= 0
        return false
    elseif i > length(states)
        for (env,s,a) in zip(envs,states,actions)
            if a != CRCBS.wait(env,s) || length(get_possible_actions(env,s)) == 1 || s.t < env.goal.t
                return true
            end
            # log_info(5,solver,"action ",string(a)," ineligible with env ",string(env.schedule_node)," |A| = $(length(get_possible_actions(env,s)))")
        end
        log_info(4,solver,"action vector $(map(a->string(a),actions)) not eligible")
        return false
    elseif !(ordering[i] in idxs)
        # search_states[i+1] = search_states[i]
        # i = i + 1
        return select_action_dfs!(solver,envs,states,actions,i+1,ordering,idxs,search_state)
    else
        # idx = env.ordering_map[i]zs
        j = 0
        idx = ordering[i]
        env = envs[idx]
        s = states[idx]
        for ai in sorted_actions(env,s)
            a = actions[idx]
            c = get_transition_cost(env,s,ai)
            c0 = get_transition_cost(env,s,a)
            if (i >= search_state.reset_i) || (i < search_state.pickup_i && a == ai) || ((c >= c0 || is_valid(env,a)) && a != ai)
                actions[idx] = ai
                log_info(5,solver,"$(repeat(" ",i))i = $i, trying a=",string(ai)," from s = ",string(s),"for env ",string(env.schedule_node), " with env.goal = ",string(env.goal))
                k = get_conflict_idx(envs,states,actions,i,ordering,idxs)
                # @assert k < i "should only check for conflicts with 1:$i, but found conflict with $k"
                if k <= 0
                    # search_states[i+1] = search_states[i]
                    # i = i+1
                    # break
                    if select_action_dfs!(solver,envs,states,actions,i+1,ordering,idxs,search_state)
                        return true
                    end
                elseif !(ordering[k] in idxs)
                    # i = i - 1
                    # break
                    # return false
                else
                    log_info(5,solver,"--- conflict betweeh $i and $k")
                    j = max(k,j)
                end
            end
        end
        if j <= 0
            return false
        end
        # if j > 0
        search_state = DFS_SearchState(pickup_i=j,reset_i=0)
        # search_states[j] = search_states[i]
        # i = j
        # break
        # end
        return select_action_dfs!(solver,envs,states,actions,j,ordering,idxs,search_state) #
    end
    # end
end
function prioritized_dfs_search(solver,search_env,envs,paths;
        t0 = max(0, minimum(map(path->length(path),paths))),
        max_iters = 4*(maximum(search_env.cache.tF)-minimum(map(p->length(p),paths))),
        search_state = DFS_SearchState()
        )
     tip_times = map(path->length(path),paths)
     t = t0
     log_info(3,solver,"start time t0=$t0")
     states     = map(path->get_s(get_path_node(path,t+1)), paths)
     actions    = map(path->get_a(get_path_node(path,t+1)), paths)
     iter = 0
     while true && iter < max_iters
         iter += 1
         # Update cache to reflect any delay ?
         update_envs!(solver,search_env,envs,paths)
         # if all(map(i->is_goal(envs[i],states[i]),1:length(paths)))
         if length(search_env.cache.active_set) == 0
             return envs, paths, true
         end
         log_info(4,solver,"envs: $(string(map(e->string(e.schedule_node),envs))...)")
         log_info(4,solver,"path_lengths = $(map(path->length(path),paths))")
         log_info(4,solver,"states: $(string(map(s->string(s),states))...)")
         @assert all(map(path->length(path)>=t,paths))
         ordering   = select_ordering(solver,search_env,envs)
         idxs       = Set(findall(tip_times .<= t))
         log_info(4,solver,"idxs: $idxs")
         if select_action_dfs!(solver,envs,states,actions,1,ordering,idxs,search_state)
             log_info(4,solver,"actions: $(string(map(a->string(a),actions))...)")
             # step forward in search
             for idx in idxs
                 env = envs[idx]
                 path = paths[idx]
                 s = states[idx]
                 a = actions[idx]
                 sp = get_next_state(envs[idx],s,a)
                 push!(path.path_nodes,PathNode(s,a,sp))
                 path.cost = accumulate_cost(env,path.cost,get_transition_cost(env,s,a,sp))
             end
             t += 1
             search_state = DFS_SearchState()
             log_info(3,solver,"stepping forward, t = $t")
         else
             # step backward in search
             all(tip_times .> t) == 0 ? break : nothing
             for (idx,path) in enumerate(paths)
                 if tip_times[idx] < t
                     pop!(path.path_nodes)
                     @assert length(path) == t-1
                 end
             end
             t -= 1
             idxs    = Set(findall(tip_times .<= t))
              # start new search where previous search left off
             search_state = DFS_SearchState(pickup_i = maximum(idxs))
             log_info(-1,solver,"stepping backward, t = $t")
         end
         states     = map(path->get_s(get_path_node(path,t+1)), paths)
         actions    = map(path->get_a(get_path_node(path,t+1)), paths)
     end
     if iter > max_iters
         # throw(SolverCBSMaxOutException("ERROR in DFS: max_iters exceeded before finding a valid route plan!"))
         throw(AssertionError("ERROR in DFS: max_iters exceeded before finding a valid route plan!"))
     end
     return envs, paths, false
end
"""
    Iterate over agents in order of priority, allowing them to fill in a
    reservation table for the vtxs they would like to occupy at the next time
    step(s).
"""
function CRCBS.solve!(
    solver::DFSRoutePlanner,
    mapf::P;kwargs...) where {P<:PC_MAPF}

    search_env = mapf.env
    update_planning_cache!(solver,search_env) # NOTE to get rid of all nodes that don't need planning but are in the active set

    route_plan = deepcopy(search_env.route_plan)
    paths = get_paths(route_plan)
    envs = Vector{PCCBS.LowLevelEnv}([PCCBS.LowLevelEnv() for p in paths])
    cbs_node = initialize_root_node(search_env)
    for i in 1:search_env.num_agents
        node_id = get_next_node_matching_agent_id(search_env.schedule,search_env.cache,i)
        envs[i], _ = build_env(solver,search_env,cbs_node,get_vtx(search_env.schedule,node_id))
    end

    envs, paths, status = prioritized_dfs_search(solver,search_env,envs,paths;
        max_iters = solver.cbs_model.max_iters
    )
    if validate(search_env.schedule,convert_to_vertex_lists(route_plan),search_env.cache.t0,search_env.cache.tF)
        log_info(0,solver,"DFS: Succeeded in finding a valid route plan!")
    else
        # throw(SolverCBSMaxOutException("ERROR in DFS! Failed to find a valid route plan!"))
        # DUMP
        filename = joinpath(DEBUG_PATH,string("DFS_demo",get_debug_file_id(),".jld2"))
        mkpath(DEBUG_PATH)
        for env in envs
            v = get_vtx(search_env.schedule,env.node_id)
            log_info(-1,solver,"node ",string(env.schedule_node)," t0=$(search_env.cache.t0[v]), tF=$(search_env.cache.tF[v]), closed=$(v in search_env.cache.closed_set),")
        end
        robot_paths = convert_to_vertex_lists(route_plan)
        object_paths, object_intervals, object_ids, path_idxs = get_object_paths(route_plan,search_env)
        log_info(-1,solver,"Dumping DFS route plan to $filename")
        @save filename robot_paths object_paths object_intervals object_ids path_idxs

        throw(AssertionError("ERROR in DFS! Failed to find a valid route plan!"))
    end
    # for (path,base_path,env) in zip(paths,search_env.route_plan.paths,envs)
    #     c = base_path.cost
    #     for p in path.path_nodes[length(base_path)+1:end]
    #         c = accumulate_cost(env,c,get_transition_cost(env,p.s,p.a,p.sp))
    #     end
    #     path.cost = c
    # end
    cost = aggregate_costs(get_cost_model(search_env),map(p->get_cost(p),paths))

    return route_plan, search_env.cache, cost
end

end