/* For "ld -r" of a Rust crate (scripts/rust_link.sh): one CIE of 20 bytes
 * at the end of .eh_frame, which no FDE uses. The size of .eh_frame then
 * changes from 4 to 0 modulo 8. The link writes this CIE as data, because
 * ld removes an unused CIE of an input file.
 *
 * The CIE: length 16, CIE id 0, version 1, no augmentation, code
 * alignment 1, data alignment -8, return register 16, and 7 bytes of
 * DW_CFA_nop. */
SECTIONS
{
  .eh_frame : {
    *(.eh_frame)
    LONG(16) LONG(0) BYTE(1) BYTE(0) BYTE(1) BYTE(0x78) BYTE(16)
    BYTE(0) BYTE(0) BYTE(0) BYTE(0) BYTE(0) BYTE(0) BYTE(0)
  }
}
INSERT AFTER .text;
