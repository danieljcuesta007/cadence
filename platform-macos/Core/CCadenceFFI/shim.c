/* Anchor TU so SwiftPM treats CCadenceFFI as a buildable C target; the real
   symbols come from libcadence_ffi.a (cargo build -p cadence-ffi). */
int cadence_ffi_shim_anchor;
