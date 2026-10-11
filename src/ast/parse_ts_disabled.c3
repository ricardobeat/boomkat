// The JS grammar calls the same type-erasure interface in both builds.
module boomkat::ast @feat(NO_TYPESCRIPT);

fn void? Parser.ts_skip_type(&self, bool expression = false) { return self.unexpected()~; }
fn void? Parser.ts_skip_generic_params(&self) { return self.unexpected()~; }
fn void? Parser.ts_annotation(&self, bool optional = false, bool definite = false) { return; }
fn bool Parser.ts_type_arguments(&self) { return false; }
fn bool? Parser.ts_erase_statement(&self, bool in_namespace = false) { return false; }
fn bool Parser.ts_index_signature(&self) { return false; }
fn void Parser.ts_arrow_return_annotation(&self) { return; }
fn void? Parser.ts_class_modifiers(&self) { return; }
fn bool Parser.ts_type_specifier(&self) { return false; }
