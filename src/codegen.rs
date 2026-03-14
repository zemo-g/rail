/// Rail native compiler — Cranelift JIT backend.
/// Compiles Rail functions to native ARM64/x86_64 machine code.
/// Supports: integers, floats, strings, arithmetic, comparisons, if/else, recursion, let bindings.
/// Does not support: closures, ADTs, records, lists, lambdas.

use std::collections::HashMap;
use cranelift::prelude::*;
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{Module, Linkage, FuncId, DataDescription, DataId};
use crate::ast::*;

// ---- Runtime functions (called from JIT-compiled code) ----

extern "C" fn rail_print_i64(val: i64) -> i64 {
    println!("{}", val);
    0
}

extern "C" fn rail_print_f64(val: f64) -> i64 {
    // Print without trailing zeros: 3.14 not 3.140000
    if val == val.floor() && val.abs() < 1e15 {
        println!("{}.0", val as i64);
    } else {
        println!("{}", val);
    }
    0
}

extern "C" fn rail_print_str(ptr: *const u8, len: i64) -> i64 {
    let slice = unsafe { std::slice::from_raw_parts(ptr, len as usize) };
    if let Ok(s) = std::str::from_utf8(slice) {
        println!("{}", s);
    }
    0
}

extern "C" fn rail_int_to_float(val: i64) -> f64 {
    val as f64
}

extern "C" fn rail_floor(val: f64) -> i64 {
    val.floor() as i64
}

extern "C" fn rail_ceil(val: f64) -> i64 {
    val.ceil() as i64
}

extern "C" fn rail_abs_i64(val: i64) -> i64 {
    val.abs()
}

extern "C" fn rail_abs_f64(val: f64) -> f64 {
    val.abs()
}

// ---- Type tracking ----

/// Represents the native type of a Rail value in codegen
#[derive(Debug, Clone, Copy, PartialEq)]
enum RailType {
    Int,
    Float,
    Str,
}

impl RailType {
    fn to_cranelift(self) -> Type {
        match self {
            RailType::Int => types::I64,
            RailType::Float => types::F64,
            RailType::Str => types::I64, // pointer
        }
    }
}

/// Parse a TypeExpr into a list of param types and a return type
fn parse_type_sig(sig: &TypeExpr) -> (Vec<RailType>, RailType) {
    match sig {
        TypeExpr::Func { from, to } => {
            let param_ty = type_expr_to_rail(from);
            let (mut rest_params, ret) = parse_type_sig(to);
            let mut params = vec![param_ty];
            params.append(&mut rest_params);
            (params, ret)
        }
        other => (vec![], type_expr_to_rail(other)),
    }
}

fn type_expr_to_rail(te: &TypeExpr) -> RailType {
    match te {
        TypeExpr::Named(name) => match name.as_str() {
            "f64" | "Float" | "float" => RailType::Float,
            "str" | "String" | "string" => RailType::Str,
            _ => RailType::Int,
        },
        _ => RailType::Int,
    }
}

// ---- TCO context ----

/// Tail call optimization context. When present, self-recursive calls
/// in tail position are compiled as jumps back to the loop header block.
struct TailCallCtx {
    func_name: String,
    entry_block: Block,
    param_vars: Vec<Variable>,
}

// ---- Compiler ----

/// Tracks a string literal embedded in the JIT data section
#[allow(dead_code)]
struct StringData {
    data_id: DataId,
    len: usize,
}

pub struct Compiler {
    module: JITModule,
    ctx: codegen::Context,
    builder_ctx: FunctionBuilderContext,
    functions: HashMap<String, FuncId>,
    func_types: HashMap<String, (Vec<RailType>, RailType)>,
    strings: HashMap<String, StringData>,
    string_counter: usize,
}

impl Compiler {
    pub fn new() -> Result<Self, String> {
        let mut flag_builder = settings::builder();
        flag_builder.set("use_colocated_libcalls", "false").map_err(|e| e.to_string())?;
        flag_builder.set("is_pic", "false").map_err(|e| e.to_string())?;

        let isa_builder = cranelift_native::builder()
            .map_err(|msg| format!("host not supported: {}", msg))?;
        let isa = isa_builder
            .finish(settings::Flags::new(flag_builder))
            .map_err(|e| e.to_string())?;

        let mut jit_builder = JITBuilder::with_isa(isa, cranelift_module::default_libcall_names());
        jit_builder.symbol("rail_print_i64", rail_print_i64 as *const u8);
        jit_builder.symbol("rail_print_f64", rail_print_f64 as *const u8);
        jit_builder.symbol("rail_print_str", rail_print_str as *const u8);
        jit_builder.symbol("rail_int_to_float", rail_int_to_float as *const u8);
        jit_builder.symbol("rail_floor", rail_floor as *const u8);
        jit_builder.symbol("rail_ceil", rail_ceil as *const u8);
        jit_builder.symbol("rail_abs_i64", rail_abs_i64 as *const u8);
        jit_builder.symbol("rail_abs_f64", rail_abs_f64 as *const u8);

        let module = JITModule::new(jit_builder);
        let ctx = module.make_context();
        let builder_ctx = FunctionBuilderContext::new();

        Ok(Compiler {
            module,
            ctx,
            builder_ctx,
            functions: HashMap::new(),
            func_types: HashMap::new(),
            strings: HashMap::new(),
            string_counter: 0,
        })
    }

    pub fn compile_and_run(&mut self, program: &Program) -> Result<i64, String> {
        self.compile_program(program)?;
        self.run_main()
    }

    fn declare_runtime_func(&mut self, name: &str, rail_name: &str, params: &[Type], returns: &[Type]) -> Result<(), String> {
        let mut sig = self.module.make_signature();
        for p in params {
            sig.params.push(AbiParam::new(*p));
        }
        for r in returns {
            sig.returns.push(AbiParam::new(*r));
        }
        let func_id = self.module.declare_function(name, Linkage::Import, &sig)
            .map_err(|e| e.to_string())?;
        self.functions.insert(rail_name.to_string(), func_id);
        Ok(())
    }

    fn compile_program(&mut self, program: &Program) -> Result<(), String> {
        // Declare runtime functions
        // print dispatches based on arg type at call site, so we register variants
        self.declare_runtime_func("rail_print_i64", "print_i64", &[types::I64], &[types::I64])?;
        self.declare_runtime_func("rail_print_f64", "print_f64", &[types::F64], &[types::I64])?;
        self.declare_runtime_func("rail_print_str", "print_str", &[types::I64, types::I64], &[types::I64])?;
        self.declare_runtime_func("rail_int_to_float", "int_to_float", &[types::I64], &[types::F64])?;
        self.declare_runtime_func("rail_floor", "floor", &[types::F64], &[types::I64])?;
        self.declare_runtime_func("rail_ceil", "ceil", &[types::F64], &[types::I64])?;
        self.declare_runtime_func("rail_abs_i64", "abs_i64", &[types::I64], &[types::I64])?;
        self.declare_runtime_func("rail_abs_f64", "abs_f64", &[types::F64], &[types::F64])?;

        // Also register "print" as print_i64 for backwards compat (overridden at call site)
        let print_i64_id = self.functions["print_i64"];
        self.functions.insert("print".to_string(), print_i64_id);

        // Pass 0: Collect type signatures
        for decl in &program.declarations {
            if let Decl::Func { name, type_sig: Some(sig), params, .. } = decl {
                let (param_types, ret_type) = parse_type_sig(sig);
                // If sig has fewer params than actual params, pad with Int
                let mut full_params = param_types;
                while full_params.len() < params.len() {
                    full_params.push(RailType::Int);
                }
                self.func_types.insert(name.clone(), (full_params, ret_type));
            }
        }

        // Pass 1: Declare all functions with proper types
        for decl in &program.declarations {
            if let Decl::Func { name, params, .. } = decl {
                let mut sig = self.module.make_signature();
                if let Some((param_types, ret_type)) = self.func_types.get(name) {
                    for (i, _) in params.iter().enumerate() {
                        let ty = param_types.get(i).copied().unwrap_or(RailType::Int);
                        sig.params.push(AbiParam::new(ty.to_cranelift()));
                    }
                    sig.returns.push(AbiParam::new(ret_type.to_cranelift()));
                } else {
                    // No type sig — default to all I64
                    for _ in 0..params.len() {
                        sig.params.push(AbiParam::new(types::I64));
                    }
                    sig.returns.push(AbiParam::new(types::I64));
                }
                let func_id = self.module.declare_function(name, Linkage::Local, &sig)
                    .map_err(|e| e.to_string())?;
                self.functions.insert(name.clone(), func_id);
            }
        }

        // Pass 2: Compile all function bodies
        for decl in &program.declarations {
            if let Decl::Func { name, params, body, .. } = decl {
                self.compile_function(name, params, body)?;
            }
        }

        self.module.finalize_definitions()
            .map_err(|e| e.to_string())?;

        Ok(())
    }

    fn intern_string(&mut self, s: &str) -> Result<DataId, String> {
        if let Some(sd) = self.strings.get(s) {
            return Ok(sd.data_id);
        }

        let name = format!("__str_{}", self.string_counter);
        self.string_counter += 1;

        let data_id = self.module.declare_data(&name, Linkage::Local, false, false)
            .map_err(|e| e.to_string())?;

        let mut desc = DataDescription::new();
        desc.define(s.as_bytes().to_vec().into_boxed_slice());

        self.module.define_data(data_id, &desc)
            .map_err(|e| e.to_string())?;

        self.strings.insert(s.to_string(), StringData { data_id, len: s.len() });
        Ok(data_id)
    }

    fn compile_function(&mut self, name: &str, params: &[Pattern], body: &Expr) -> Result<(), String> {
        let func_id = self.functions[name];

        let sig = self.module
            .declarations()
            .get_function_decl(func_id)
            .signature
            .clone();

        self.ctx.func.signature = sig;

        let functions = self.functions.clone();
        let func_types = self.func_types.clone();

        // Intern all string literals in the body before building
        let string_ids = self.collect_and_intern_strings(body)?;

        {
            let mut builder = FunctionBuilder::new(&mut self.ctx.func, &mut self.builder_ctx);
            let entry = builder.create_block();
            builder.append_block_params_for_function_params(entry);
            builder.switch_to_block(entry);

            let mut vars = HashMap::new();
            let mut var_counter = 0usize;
            let mut var_types = HashMap::new();
            let mut param_vars = Vec::new();

            // Get param types from func_types
            let param_type_info = func_types.get(name);

            for (i, param) in params.iter().enumerate() {
                if let Pattern::Var(pname) = param {
                    let cl_type = builder.func.dfg.value_type(builder.block_params(entry)[i]);
                    let var = Variable::new(var_counter);
                    var_counter += 1;
                    builder.declare_var(var, cl_type);
                    let param_val = builder.block_params(entry)[i];
                    builder.def_var(var, param_val);
                    vars.insert(pname.clone(), var);
                    param_vars.push(var);

                    // Track rail type
                    let rail_ty = if let Some((ptypes, _)) = param_type_info {
                        ptypes.get(i).copied().unwrap_or(RailType::Int)
                    } else {
                        RailType::Int
                    };
                    var_types.insert(pname.clone(), rail_ty);
                }
            }

            // TCO: create loop header block for self-recursive tail calls
            let loop_block = builder.create_block();
            for (i, _) in params.iter().enumerate() {
                let cl_type = builder.func.dfg.value_type(builder.block_params(entry)[i]);
                builder.append_block_param(loop_block, cl_type);
            }

            // Jump from entry to loop block with initial param values
            let initial_args: Vec<cranelift::prelude::Value> = param_vars.iter()
                .map(|v| builder.use_var(*v))
                .collect();
            builder.ins().jump(loop_block, &initial_args);

            // Switch to loop block and rebind param vars from block params
            builder.switch_to_block(loop_block);
            for (i, var) in param_vars.iter().enumerate() {
                let block_param = builder.block_params(loop_block)[i];
                builder.def_var(*var, block_param);
            }

            let tco_ctx = TailCallCtx {
                func_name: name.to_string(),
                entry_block: loop_block,
                param_vars: param_vars.clone(),
            };

            let result = compile_expr_tail(
                body, &mut builder, &mut vars, &mut var_types, &mut var_counter,
                &mut self.module, &functions, &func_types, &string_ids,
                Some(&tco_ctx),
            )?;

            builder.ins().return_(&[result]);
            builder.seal_all_blocks();
            builder.finalize();
        }

        self.module.define_function(func_id, &mut self.ctx)
            .map_err(|e| e.to_string())?;
        self.module.clear_context(&mut self.ctx);

        Ok(())
    }

    /// Walk the body and intern all string literals, returning a map of string -> DataId
    fn collect_and_intern_strings(&mut self, expr: &Expr) -> Result<HashMap<String, DataId>, String> {
        let mut ids = HashMap::new();
        self.collect_strings_inner(expr, &mut ids)?;
        Ok(ids)
    }

    fn collect_strings_inner(&mut self, expr: &Expr, ids: &mut HashMap<String, DataId>) -> Result<(), String> {
        match &expr.kind {
            ExprKind::StrLit(s) => {
                if !ids.contains_key(s) {
                    let data_id = self.intern_string(s)?;
                    ids.insert(s.clone(), data_id);
                }
            }
            ExprKind::BinOp { left, right, .. } => {
                self.collect_strings_inner(left, ids)?;
                self.collect_strings_inner(right, ids)?;
            }
            ExprKind::UnaryOp { operand, .. } => {
                self.collect_strings_inner(operand, ids)?;
            }
            ExprKind::App { func, arg } => {
                self.collect_strings_inner(func, ids)?;
                self.collect_strings_inner(arg, ids)?;
            }
            ExprKind::Let { value, body, .. } => {
                self.collect_strings_inner(value, ids)?;
                self.collect_strings_inner(body, ids)?;
            }
            ExprKind::If { cond, then_branch, else_branch } => {
                self.collect_strings_inner(cond, ids)?;
                self.collect_strings_inner(then_branch, ids)?;
                self.collect_strings_inner(else_branch, ids)?;
            }
            ExprKind::Match { scrutinee, arms } => {
                self.collect_strings_inner(scrutinee, ids)?;
                for arm in arms {
                    self.collect_strings_inner(&arm.body, ids)?;
                }
            }
            ExprKind::Pipe { value, func } => {
                self.collect_strings_inner(value, ids)?;
                self.collect_strings_inner(func, ids)?;
            }
            ExprKind::Block(exprs) => {
                for e in exprs {
                    self.collect_strings_inner(e, ids)?;
                }
            }
            ExprKind::Tuple(exprs) | ExprKind::List(exprs) => {
                for e in exprs {
                    self.collect_strings_inner(e, ids)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn run_main(&mut self) -> Result<i64, String> {
        let func_id = *self.functions.get("main")
            .ok_or("no 'main' function defined")?;
        let code_ptr = self.module.get_finalized_function(func_id);
        let main_fn: fn() -> i64 = unsafe { std::mem::transmute(code_ptr) };
        Ok(main_fn())
    }
}

// ---- Expression compiler (free function to avoid borrow issues) ----

fn compile_expr(
    expr: &Expr,
    builder: &mut FunctionBuilder,
    vars: &mut HashMap<String, Variable>,
    var_types: &mut HashMap<String, RailType>,
    var_counter: &mut usize,
    module: &mut JITModule,
    functions: &HashMap<String, FuncId>,
    func_types: &HashMap<String, (Vec<RailType>, RailType)>,
    string_ids: &HashMap<String, DataId>,
) -> Result<Value, String> {
    compile_expr_tail(expr, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, None)
}

/// Compile an expression, optionally in tail position with TCO context.
fn compile_expr_tail(
    expr: &Expr,
    builder: &mut FunctionBuilder,
    vars: &mut HashMap<String, Variable>,
    var_types: &mut HashMap<String, RailType>,
    var_counter: &mut usize,
    module: &mut JITModule,
    functions: &HashMap<String, FuncId>,
    func_types: &HashMap<String, (Vec<RailType>, RailType)>,
    string_ids: &HashMap<String, DataId>,
    tco_ctx: Option<&TailCallCtx>,
) -> Result<Value, String> {
    let span = expr.span;
    match &expr.kind {
        ExprKind::IntLit(n) => Ok(builder.ins().iconst(types::I64, *n)),

        ExprKind::FloatLit(f) => Ok(builder.ins().f64const(*f)),

        ExprKind::BoolLit(b) => Ok(builder.ins().iconst(types::I64, if *b { 1 } else { 0 })),

        ExprKind::StrLit(s) => {
            // Load pointer to interned string data
            let data_id = string_ids.get(s)
                .ok_or_else(|| format!("string not interned: {:?}", s))?;
            let gv = module.declare_data_in_func(*data_id, builder.func);
            let ptr = builder.ins().global_value(types::I64, gv);
            Ok(ptr)
        }

        ExprKind::Var(name) => {
            if let Some(var) = vars.get(name) {
                Ok(builder.use_var(*var))
            } else if let Some(&func_id) = functions.get(name) {
                // Zero-arg function call (thunk)
                let func_ref = module.declare_func_in_func(func_id, builder.func);
                let call = builder.ins().call(func_ref, &[]);
                Ok(builder.inst_results(call)[0])
            } else {
                Err(format!("error at {}:{}: undefined variable in codegen: '{}'", span.0, span.1, name))
            }
        }

        ExprKind::BinOp { op, left, right } => {
            let l = compile_expr(left, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
            let r = compile_expr(right, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;

            let l_type = builder.func.dfg.value_type(l);
            let is_float = l_type == types::F64;

            if is_float {
                match op.as_str() {
                    "+" => Ok(builder.ins().fadd(l, r)),
                    "-" => Ok(builder.ins().fsub(l, r)),
                    "*" => Ok(builder.ins().fmul(l, r)),
                    "/" => Ok(builder.ins().fdiv(l, r)),
                    "==" => {
                        let cmp = builder.ins().fcmp(FloatCC::Equal, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "!=" => {
                        let cmp = builder.ins().fcmp(FloatCC::NotEqual, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "<" => {
                        let cmp = builder.ins().fcmp(FloatCC::LessThan, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    ">" => {
                        let cmp = builder.ins().fcmp(FloatCC::GreaterThan, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "<=" => {
                        let cmp = builder.ins().fcmp(FloatCC::LessThanOrEqual, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    ">=" => {
                        let cmp = builder.ins().fcmp(FloatCC::GreaterThanOrEqual, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    _ => Err(format!("error at {}:{}: unsupported float operator in codegen: {}", span.0, span.1, op)),
                }
            } else {
                match op.as_str() {
                    "+" => Ok(builder.ins().iadd(l, r)),
                    "-" => Ok(builder.ins().isub(l, r)),
                    "*" => Ok(builder.ins().imul(l, r)),
                    "/" => Ok(builder.ins().sdiv(l, r)),
                    "%" => Ok(builder.ins().srem(l, r)),
                    "==" => {
                        let cmp = builder.ins().icmp(IntCC::Equal, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "!=" => {
                        let cmp = builder.ins().icmp(IntCC::NotEqual, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "<" => {
                        let cmp = builder.ins().icmp(IntCC::SignedLessThan, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    ">" => {
                        let cmp = builder.ins().icmp(IntCC::SignedGreaterThan, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "<=" => {
                        let cmp = builder.ins().icmp(IntCC::SignedLessThanOrEqual, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    ">=" => {
                        let cmp = builder.ins().icmp(IntCC::SignedGreaterThanOrEqual, l, r);
                        Ok(builder.ins().uextend(types::I64, cmp))
                    }
                    "&&" => Ok(builder.ins().band(l, r)),
                    "||" => Ok(builder.ins().bor(l, r)),
                    _ => Err(format!("error at {}:{}: unsupported operator in codegen: {}", span.0, span.1, op)),
                }
            }
        }

        ExprKind::UnaryOp { op, operand } => {
            let v = compile_expr(operand, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
            let v_type = builder.func.dfg.value_type(v);
            match op.as_str() {
                "-" if v_type == types::F64 => Ok(builder.ins().fneg(v)),
                "-" => Ok(builder.ins().ineg(v)),
                _ => Err(format!("error at {}:{}: unsupported unary op in codegen: {}", span.0, span.1, op)),
            }
        }

        ExprKind::If { cond, then_branch, else_branch } => {
            let cond_val = compile_expr(cond, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;

            let then_block = builder.create_block();
            let else_block = builder.create_block();
            let merge_block = builder.create_block();

            // Branch on condition (nonzero = true)
            let cond_bool = builder.ins().icmp_imm(IntCC::NotEqual, cond_val, 0);
            builder.ins().brif(cond_bool, then_block, &[], else_block, &[]);

            // Then branch — propagate tail position
            builder.switch_to_block(then_block);
            let then_val = compile_expr_tail(then_branch, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
            let result_type = builder.func.dfg.value_type(then_val);
            builder.ins().jump(merge_block, &[then_val]);

            // Else branch — propagate tail position
            builder.switch_to_block(else_block);
            let else_val = compile_expr_tail(else_branch, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
            builder.ins().jump(merge_block, &[else_val]);

            // Merge — use the type from then branch
            builder.append_block_param(merge_block, result_type);
            builder.switch_to_block(merge_block);
            Ok(builder.block_params(merge_block)[0])
        }

        ExprKind::App { .. } => {
            // Flatten curried application: f a b -> call f(a, b)
            let (func_kind, func_span, args) = flatten_app(expr);

            // Check for self-recursive tail call optimization
            if let Some(ctx) = tco_ctx {
                if let ExprKind::Var(name) = func_kind {
                    if name == &ctx.func_name && args.len() == ctx.param_vars.len() {
                        // Self-recursive tail call — compile args, jump to loop header
                        let compiled_args: Result<Vec<Value>, String> = args.iter()
                            .map(|a| compile_expr(a, builder, vars, var_types, var_counter, module, functions, func_types, string_ids))
                            .collect();
                        let compiled_args = compiled_args?;

                        builder.ins().jump(ctx.entry_block, &compiled_args);

                        // Return dummy value from unreachable block
                        let unreachable_block = builder.create_block();
                        builder.switch_to_block(unreachable_block);
                        let ret_type = func_types.get(&ctx.func_name)
                            .map(|(_, rt)| rt.to_cranelift())
                            .unwrap_or(types::I64);
                        if ret_type == types::F64 {
                            return Ok(builder.ins().f64const(0.0));
                        } else {
                            return Ok(builder.ins().iconst(types::I64, 0));
                        }
                    }
                }
            }

            match func_kind {
                ExprKind::Var(name) if name == "print" => {
                    // Dispatch print based on argument type
                    if args.len() != 1 {
                        return Err("print takes exactly 1 argument".to_string());
                    }
                    let arg_val = compile_expr(args[0], builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
                    let arg_type = builder.func.dfg.value_type(arg_val);

                    // Check if the arg is a string literal
                    if let ExprKind::StrLit(s) = &args[0].kind {
                        let func_id = functions["print_str"];
                        let func_ref = module.declare_func_in_func(func_id, builder.func);
                        let len = builder.ins().iconst(types::I64, s.len() as i64);
                        let call = builder.ins().call(func_ref, &[arg_val, len]);
                        Ok(builder.inst_results(call)[0])
                    } else if arg_type == types::F64 {
                        let func_id = functions["print_f64"];
                        let func_ref = module.declare_func_in_func(func_id, builder.func);
                        let call = builder.ins().call(func_ref, &[arg_val]);
                        Ok(builder.inst_results(call)[0])
                    } else {
                        let func_id = functions["print_i64"];
                        let func_ref = module.declare_func_in_func(func_id, builder.func);
                        let call = builder.ins().call(func_ref, &[arg_val]);
                        Ok(builder.inst_results(call)[0])
                    }
                }
                ExprKind::Var(name) if name == "int_to_float" => {
                    if args.len() != 1 {
                        return Err("int_to_float takes exactly 1 argument".to_string());
                    }
                    let arg_val = compile_expr(args[0], builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
                    let func_id = functions["int_to_float"];
                    let func_ref = module.declare_func_in_func(func_id, builder.func);
                    let call = builder.ins().call(func_ref, &[arg_val]);
                    Ok(builder.inst_results(call)[0])
                }
                ExprKind::Var(name) if name == "floor" => {
                    if args.len() != 1 { return Err("floor takes exactly 1 argument".to_string()); }
                    let arg_val = compile_expr(args[0], builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
                    let func_id = functions["floor"];
                    let func_ref = module.declare_func_in_func(func_id, builder.func);
                    let call = builder.ins().call(func_ref, &[arg_val]);
                    Ok(builder.inst_results(call)[0])
                }
                ExprKind::Var(name) if name == "ceil" => {
                    if args.len() != 1 { return Err("ceil takes exactly 1 argument".to_string()); }
                    let arg_val = compile_expr(args[0], builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
                    let func_id = functions["ceil"];
                    let func_ref = module.declare_func_in_func(func_id, builder.func);
                    let call = builder.ins().call(func_ref, &[arg_val]);
                    Ok(builder.inst_results(call)[0])
                }
                ExprKind::Var(name) if name == "abs" => {
                    if args.len() != 1 { return Err("abs takes exactly 1 argument".to_string()); }
                    let arg_val = compile_expr(args[0], builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
                    let arg_type = builder.func.dfg.value_type(arg_val);
                    let key = if arg_type == types::F64 { "abs_f64" } else { "abs_i64" };
                    let func_id = functions[key];
                    let func_ref = module.declare_func_in_func(func_id, builder.func);
                    let call = builder.ins().call(func_ref, &[arg_val]);
                    Ok(builder.inst_results(call)[0])
                }
                ExprKind::Var(name) => {
                    if let Some(&func_id) = functions.get(name) {
                        let func_ref = module.declare_func_in_func(func_id, builder.func);
                        let compiled_args: Result<Vec<Value>, String> = args.iter()
                            .map(|a| compile_expr(a, builder, vars, var_types, var_counter, module, functions, func_types, string_ids))
                            .collect();
                        let call = builder.ins().call(func_ref, &compiled_args?);
                        Ok(builder.inst_results(call)[0])
                    } else {
                        Err(format!("error at {}:{}: unknown function in codegen: '{}'", func_span.0, func_span.1, name))
                    }
                }
                _ => Err("only named function calls supported in native codegen".to_string()),
            }
        }

        ExprKind::Let { name, value, body } => {
            let val = compile_expr(value, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
            if name != "_" {
                let val_type = builder.func.dfg.value_type(val);
                let var = Variable::new(*var_counter);
                *var_counter += 1;
                builder.declare_var(var, val_type);
                builder.def_var(var, val);
                vars.insert(name.clone(), var);

                // Track rail type
                let rail_ty = if val_type == types::F64 { RailType::Float } else { RailType::Int };
                var_types.insert(name.clone(), rail_ty);
            }
            compile_expr_tail(body, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)
        }

        ExprKind::Block(exprs) => {
            let mut result = builder.ins().iconst(types::I64, 0);
            for (i, e) in exprs.iter().enumerate() {
                if i == exprs.len() - 1 {
                    // Last expression is in tail position
                    result = compile_expr_tail(e, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
                } else {
                    result = compile_expr(e, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
                }
            }
            Ok(result)
        }

        ExprKind::Pipe { value, func } => {
            // x |> f -> f(x)
            let v = compile_expr(value, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
            match &func.kind {
                ExprKind::Var(name) if name == "print" => {
                    let v_type = builder.func.dfg.value_type(v);
                    let key = if v_type == types::F64 { "print_f64" } else { "print_i64" };
                    let func_id = functions[key];
                    let func_ref = module.declare_func_in_func(func_id, builder.func);
                    let call = builder.ins().call(func_ref, &[v]);
                    Ok(builder.inst_results(call)[0])
                }
                ExprKind::Var(name) => {
                    if let Some(&func_id) = functions.get(name) {
                        let func_ref = module.declare_func_in_func(func_id, builder.func);
                        let call = builder.ins().call(func_ref, &[v]);
                        Ok(builder.inst_results(call)[0])
                    } else {
                        Err(format!("error at {}:{}: unknown function in pipe codegen: '{}'", func.span.0, func.span.1, name))
                    }
                }
                _ => Err("pipe target must be a named function in native codegen".to_string()),
            }
        }

        ExprKind::Match { scrutinee, arms } => {
            let scrut_val = compile_expr(scrutinee, builder, vars, var_types, var_counter, module, functions, func_types, string_ids)?;
            compile_match_chain(scrut_val, arms, 0, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)
        }

        _ => Err(format!("error at {}:{}: unsupported expression in native codegen: {:?}", span.0, span.1, std::mem::discriminant(&expr.kind))),
    }
}

fn compile_match_chain(
    scrut: Value,
    arms: &[MatchArm],
    idx: usize,
    builder: &mut FunctionBuilder,
    vars: &mut HashMap<String, Variable>,
    var_types: &mut HashMap<String, RailType>,
    var_counter: &mut usize,
    module: &mut JITModule,
    functions: &HashMap<String, FuncId>,
    func_types: &HashMap<String, (Vec<RailType>, RailType)>,
    string_ids: &HashMap<String, DataId>,
    tco_ctx: Option<&TailCallCtx>,
) -> Result<Value, String> {
    if idx >= arms.len() {
        return Err("non-exhaustive match in codegen".to_string());
    }

    let arm = &arms[idx];
    let scrut_type = builder.func.dfg.value_type(scrut);

    match &arm.pattern {
        Pattern::Wildcard | Pattern::Var(_) => {
            if let Pattern::Var(name) = &arm.pattern {
                let var = Variable::new(*var_counter);
                *var_counter += 1;
                builder.declare_var(var, scrut_type);
                builder.def_var(var, scrut);
                vars.insert(name.clone(), var);
                let rail_ty = if scrut_type == types::F64 { RailType::Float } else { RailType::Int };
                var_types.insert(name.clone(), rail_ty);
            }
            compile_expr_tail(&arm.body, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)
        }
        Pattern::IntLit(n) => {
            let lit = builder.ins().iconst(types::I64, *n);
            let cmp = builder.ins().icmp(IntCC::Equal, scrut, lit);

            let then_block = builder.create_block();
            let else_block = builder.create_block();
            let merge_block = builder.create_block();

            builder.ins().brif(cmp, then_block, &[], else_block, &[]);

            builder.switch_to_block(then_block);
            let then_val = compile_expr_tail(&arm.body, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
            let result_type = builder.func.dfg.value_type(then_val);
            builder.ins().jump(merge_block, &[then_val]);

            builder.switch_to_block(else_block);
            let else_val = compile_match_chain(scrut, arms, idx + 1, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
            builder.ins().jump(merge_block, &[else_val]);

            builder.append_block_param(merge_block, result_type);
            builder.switch_to_block(merge_block);
            Ok(builder.block_params(merge_block)[0])
        }
        Pattern::BoolLit(b) => {
            let lit = builder.ins().iconst(types::I64, if *b { 1 } else { 0 });
            let cmp = builder.ins().icmp(IntCC::Equal, scrut, lit);

            let then_block = builder.create_block();
            let else_block = builder.create_block();
            let merge_block = builder.create_block();

            builder.ins().brif(cmp, then_block, &[], else_block, &[]);

            builder.switch_to_block(then_block);
            let then_val = compile_expr_tail(&arm.body, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
            let result_type = builder.func.dfg.value_type(then_val);
            builder.ins().jump(merge_block, &[then_val]);

            builder.switch_to_block(else_block);
            let else_val = compile_match_chain(scrut, arms, idx + 1, builder, vars, var_types, var_counter, module, functions, func_types, string_ids, tco_ctx)?;
            builder.ins().jump(merge_block, &[else_val]);

            builder.append_block_param(merge_block, result_type);
            builder.switch_to_block(merge_block);
            Ok(builder.block_params(merge_block)[0])
        }
        _ => Err(format!("unsupported pattern in native codegen: {:?}", arm.pattern)),
    }
}

/// Flatten curried application, returning the function's ExprKind, span, and arg list
fn flatten_app<'a>(expr: &'a Expr) -> (&'a ExprKind, Span, Vec<&'a Expr>) {
    match &expr.kind {
        ExprKind::App { func, arg } => {
            let (f, f_span, mut args) = flatten_app(func);
            args.push(arg);
            (f, f_span, args)
        }
        other => (other, expr.span, vec![]),
    }
}
