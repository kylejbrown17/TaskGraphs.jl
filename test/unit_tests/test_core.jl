let
    reset_debug_file_id!()
    @test get_debug_file_id() == 1
    @test get_debug_file_id() == 2
    reset_debug_file_id!()
end
let
    spec = ProblemSpec()
    get_distance(spec,1,1)
end
let
    spec = ProjectSpec()

    TaskGraphs.set_initial_condition!(spec,ObjectID(1),OBJECT_AT(1,1))
    @test TaskGraphs.get_initial_condition(spec,ObjectID(1)) == OBJECT_AT(1,1)
    TaskGraphs.set_initial_condition!(spec,ObjectID(2),OBJECT_AT(2,1))
    @test TaskGraphs.get_initial_condition(spec,ObjectID(2)) == OBJECT_AT(2,1)
    TaskGraphs.set_final_condition!(spec,ObjectID(1),OBJECT_AT(1,2))
    @test TaskGraphs.get_final_condition(spec,ObjectID(1)) == OBJECT_AT(1,2)
    TaskGraphs.set_final_condition!(spec,ObjectID(1),OBJECT_AT(1,3))
    @test TaskGraphs.get_final_condition(spec,ObjectID(1)) == OBJECT_AT(1,3)
    TaskGraphs.set_final_condition!(spec,ObjectID(2),OBJECT_AT(2,3))
    @test TaskGraphs.get_final_condition(spec,ObjectID(2)) == OBJECT_AT(2,3)

    # add operations to a ProjectSpec and test that the dependencies are
    # stored correctly
    op1 = construct_operation(spec,-1,[],[1],0.0)
    op2 = construct_operation(spec,-1,[1],[2],0.0)
    op3 = construct_operation(spec,-1,[2],[],0.0)
    add_operation!(spec,op1)
    add_operation!(spec,op2)
    add_operation!(spec,op3)
    @test has_edge(spec, get_operation_id(op1), ObjectID(1))
    @test has_edge(spec, ObjectID(1), get_operation_id(op2))
    @test has_edge(spec, get_operation_id(op2), ObjectID(2))
    @test has_edge(spec, ObjectID(2), get_operation_id(op3))

    # now reset the spec to empty and see if the operations can be safely added
    spec = ProjectSpec()
    add_operation!(spec,op1)
    add_operation!(spec,op2)
    add_operation!(spec,op3)
    @test has_edge(spec, get_operation_id(op1), ObjectID(1))
    @test has_edge(spec, ObjectID(1), get_operation_id(op2))
    @test has_edge(spec, get_operation_id(op2), ObjectID(2))
    @test has_edge(spec, ObjectID(2), get_operation_id(op3))

end
let
    def = SimpleProblemDef(
        project_spec = ProjectSpec(),
        r0 = [1,2,3],
        s0 = [1,2,3],
        sF = [1,2,3],
    )
    @test length(def.shapes) == length(def.s0)
end
# ProjectSpec
let
    M = 3
    object_ICs = Vector{OBJECT_AT}([
        OBJECT_AT(1,1),
        OBJECT_AT(2,2),
        OBJECT_AT(3,3)
        ])
    object_FCs = Vector{OBJECT_AT}([
        OBJECT_AT(1,4),
        OBJECT_AT(2,5),
        OBJECT_AT(3,6)
        ])
    robot_ICs = [
        ROBOT_AT(1,7),
        ROBOT_AT(2,8),
        ROBOT_AT(3,9)
        ]
    # Testing root nodes
    let
        project_spec = ProjectSpec(object_ICs,object_FCs)
        add_operation!(project_spec,construct_operation(project_spec, 3, [1,2], [3], 1.0))
        add_operation!(project_spec,construct_operation(project_spec, 6, [3], [], 0.0))
    end
    let
        project_spec = ProjectSpec(object_ICs,object_FCs)
        add_operation!(project_spec,construct_operation(project_spec, 3, [1,2], [], 1.0))
        add_operation!(project_spec,construct_operation(project_spec, 6, [3], [], 0.0))
    end
    let
        project_spec = ProjectSpec(object_ICs,object_FCs)
        add_operation!(project_spec,construct_operation(project_spec, 3, [1,2], [3], 1.0))
        add_operation!(project_spec,construct_operation(project_spec, 6, [3], [], 0.0))
        delivery_graph = construct_delivery_graph(project_spec,M)
    end
end
let
    solver = NBSSolver()
    prob = pctapf_problem_1(solver)
    env = get_env(prob)
    sched = get_schedule(env)
    spec = get_problem_spec(env)
    n = OBJECT_AT(1,1)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == false
    n = ROBOT_AT(1,1)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.min_duration == 0
    @test s.free         == true
    n = GO(1,1,2)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.min_duration == 1
    @test s.tight        == true
    @test s.free         == false
    n = GO(1,1,-1)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.min_duration == 0
    @test s.tight        == true
    @test s.free         == true
    n = CARRY(1,1,1,2)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.min_duration == 1
    @test s.tight == false
    @test s.free  == false
    n = COLLECT(1,1,1)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.tight == false
    @test s.free  == false
    @test s.static == true
    n = DEPOSIT(1,1,1)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.tight == false
    @test s.free  == false
    @test s.static == true
    n = Operation(Δt=4)
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == false
    @test s.min_duration == duration(n)
    n = TEAM_ACTION{DeliveryBot,GO}(instructions=[GO(1,1,2)])
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.free      == false
    @test s.static    == false
    @test s.tight     == true
    @test s.min_duration == 1
    n = TEAM_ACTION{DeliveryBot,CARRY}(instructions=[CARRY(1,1,1,2)])
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.free      == false
    @test s.tight     == false
    @test s.static    == false
    @test s.min_duration == 1
    n = TEAM_ACTION{DeliveryBot,COLLECT}(instructions=[COLLECT(1,1,1)])
    s = generate_path_spec(sched,spec,n)
    @test s.plan_path == true
    @test s.free      == false
    @test s.tight     == false
    @test s.static    == true
end
let
    sched = OperatingSchedule()
    node = OBJECT_AT(1,1)
    add_node!(sched,make_node(sched,node)) 
    replace_in_schedule!(sched,make_node(sched,node)) 
    get_path_spec(sched,1)
    set_path_spec!(sched,1,get_path_spec(sched,1))
    for pred in [
            OBJECT_AT(1,2),
            ROBOT_AT(1,2),
            GO(),
            COLLECT(),
            CARRY(),
            DEPOSIT(),
            TEAM_CARRY(instructions=[CARRY()])
            ]
        generate_path_spec(sched,pred)
    end

    get_graph(sched)
    get_vtx_ids(sched)

    id = get_object_id(node)
    get_node_from_id(sched,id)
    get_vtx(sched,id)
    v = 1
    get_vtx_id(sched,v)
    get_node_from_vtx(sched,v)

    get_object_ICs(sched)
    get_robot_ICs(sched)
    get_actions(sched)
    get_operations(sched)

    zero(sched)
    LightGraphs.edges(sched)
    LightGraphs.edgetype(sched)
    LightGraphs.has_edge(sched,1,1)
    LightGraphs.has_vertex(sched,1)
    LightGraphs.inneighbors(sched,1)
    LightGraphs.outneighbors(sched,1)
    LightGraphs.is_directed(sched)
    LightGraphs.ne(sched)
    LightGraphs.nv(sched)
    LightGraphs.vertices(sched)
end
let
    # test node deletion
    sched = OperatingSchedule()
    nodes = [OBJECT_AT(1,1),OBJECT_AT(2,2),OBJECT_AT(3,3)]
    for node in nodes
        add_node!(sched,make_node(sched,node)) 
    end
    rem_nodes!(sched,[1,2])
    @test get_node_from_vtx(sched,1) == OBJECT_AT(3,3)
end
# Test process_schedule
let
    solver = TaskGraphsMILPSolver(AssignmentMILP())
    # project_spec, problem_spec, robot_ICs, env_graph, _ = pctapf_problem_1()
    sched, problem_spec, env_graph, _ = pctapf_problem_1()

    # sched = construct_partial_project_schedule(project_spec,problem_spec,robot_ICs)
    model = formulate_milp(solver,sched,problem_spec;cost_model=MakeSpan())
    optimize!(model)
    @test termination_status(model) == MOI.OPTIMAL
    cost = Int(round(value(objective_function(model))))
    update_project_schedule!(solver,model,sched,problem_spec,get_assignment_matrix(model))

    TaskGraphs.process_schedule!(sched)
    @test get_t0(sched,RobotID(1)) == 0
    @test get_t0(sched,RobotID(2)) == 0
    # try with perturbed start times
    set_t0!(sched,RobotID(2),1)
    TaskGraphs.process_schedule!(sched)
    @test get_t0(sched,RobotID(1)) == 0
    @test get_t0(sched,RobotID(2)) == 1

    @test length(get_vtx_ids(sched)) == nv(get_graph(sched))
    for (v,id) in enumerate(sched.vtx_ids)
        @test get_vtx(sched, id) == v
    end
end
let
    r0 = [1,4]
    s0 = [5,8,14]
    sF = [13,12,15]
    project_spec, robot_ICs = TaskGraphs.empty_pctapf_problem(r0,s0,sF)
    add_operation!(project_spec,construct_operation(project_spec,-1,[1,2],[3],0))
    add_operation!(project_spec,construct_operation(project_spec,-1,[3],  [], 0))

    filename = "/tmp/project_spec.toml"
    open(filename, "w") do io
        TOML.print(io, TOML.parse(project_spec))
    end
    project_spec_mod = read_project_spec(filename)
    # @show project_spec_mod.object_id_to_idx
    # run(`rm $filename`)

    r0 = [get_id(get_initial_location_id(robot_ICs[k])) for k in sort(collect(keys(robot_ICs)))]
    s0 = map(pred->get_id(get_initial_location_id(pred)),TaskGraphs.initial_conditions_vector(project_spec))
    sF = map(pred->get_id(get_initial_location_id(pred)),TaskGraphs.final_conditions_vector(project_spec))
    problem_def = SimpleProblemDef(project_spec,r0,s0,sF)
    filename = "/tmp/problem_def.toml"
    open(filename, "w") do io
        TOML.print(io, TOML.parse(problem_def))
    end
    problem_def = read_problem_def(filename)
    # run(`rm $filename`)
end
let
    solver = NBSSolver()
    prob = pctapf_problem_1(solver)
    model = formulate_assignment_problem(assignment_solver(solver),prob)
    sched,_ = solve_assignment_problem!(assignment_solver(solver),model,prob)
    tips = robot_tip_map(sched)
    [k=>string(get_node_from_id(sched,id)) for (k,id) in tips]
end
let
    sched = OperatingSchedule()
    r1 = add_node!(sched, make_node(sched,ROBOT_AT(1,1), ))
    r2 = add_node!(sched, make_node(sched,ROBOT_AT(2,5), ))
    n1 = add_node!(sched, make_node(sched,GO(1,1,2),     ))
    o1 = add_node!(sched, make_node(sched,OBJECT_AT(1,2),))
    n2 = add_node!(sched, make_node(sched,COLLECT(1,1,2),))
    n3 = add_node!(sched, make_node(sched,CARRY(1,1,2,3),))
    add_edge!(sched,r1,n1) 
    add_edge!(sched,n1,n2) 
    add_edge!(sched,o1,n2) 
    add_edge!(sched,n2,n3) 
    for (n,vtxs) in [
        (n3,[get_vtx(sched,n2)]),
        (n2,[get_vtx(sched,n1)]),
        (n1,[get_vtx(sched,r1)]),
        (o1,Int[]),
        ]
        v = get_vtx(sched,n)
        @test vtxs == backtrack_node(sched,v)
    end
    tips = robot_tip_map(sched)
    @test tips[r1.id] == n3.id
    @test tips[r2.id] == r2.id
    # test tips for team
    n4 = add_node!(sched, make_node(sched,GO(2,5,3)))
    add_edge!(sched,r2,n4)
    n5 = add_node!(sched, make_node(sched,GO(1,3,2)))
    add_edge!(sched,n3,n5)
    n6 = add_node!(sched,make_node(sched,TEAM_COLLECT(instructions=[COLLECT(1,1,2),COLLECT(2,1,3),]))) #,ActionID(3))
    add_edge!(sched,n4,n6)
    add_edge!(sched,n5,n6)
    tips = robot_tip_map(sched)
    @test tips[r1.id] == n6.id
    @test tips[r2.id] == n6.id
end
let
    sched = OperatingSchedule()
    for (robot_ids, node) in [
        ([1],ROBOT_AT(1,1)),
        ([1],GO(1,1,2)),
        ([],OBJECT_AT(1,2)),
        ([1,2],TEAM_CARRY(instructions=[CARRY(1,1,2,3),CARRY(2,1,3,4)]))
        ]
        n = add_node!(sched,make_node(sched,node))
        @test get_valid_robot_ids(sched,n.id) == map(i->RobotID(i),robot_ids)
    end
end
