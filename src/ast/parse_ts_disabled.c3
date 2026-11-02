// The JS grammar calls the same type-erasure interface in both builds.
module boomkat::ast @feat(NO_TYPESCRIPT);

fn void? Parser.ts_skip_type(&self, bool expression = false) { return self.unexpected()~; }
fn void? Parser.ts_skip_generic_params(&self, bool type_args = false) { return self.unexpected()~; }
fn void? Parser.ts_annotation(&self, bool optional = false, bool definite = false) { return; }
fn bool Parser.ts_type_arguments(&self) { return false; }
fn bool? Parser.ts_erase_statement(&self, bool in_namespace = false) { return false; }
fn uint? Parser.ts_statement(&self, uint pos, bool top_level) { return 0; }
fn bool Parser.ts_index_signature(&self) { return false; }
fn void Parser.ts_arrow_return_annotation(&self) { return; }
fn void? Parser.ts_class_modifiers(&self) { return; }
fn bool Parser.ts_type_specifier(&self) { return false; }
fn bool Parser.ts_param_property(&self) { return false; }
fn uint Parser.ts_param_prop_statements(&self, uint pos, sz from) { return 0; }
fn uint Parser.ts_param_prop_at(&self, uint list, bool derived) { return 0; }
fn bool Parser.ts_import_equals_ahead(&self) { return false; }
fn uint Parser.ts_scope_push(&self) { return 0; }
fn void Parser.ts_scope_pop(&self, uint mark) { return; }
fn void Parser.ts_record_decl(&self, uint stmt) { return; }
fn void Parser.ts_elide_shadowed_imports(&self, uint mark) { return; }
