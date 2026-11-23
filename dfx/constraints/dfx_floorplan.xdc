# Floorplan for the reconfigurable partition (u_rp). Clock region X1Y3 is unused by the static design.
# SNAPPING_MODE moves the edges to legal 7-series frame boundaries; CONTAIN_ROUTING keeps RP routing inside.
create_pblock pblock_rp
add_cells_to_pblock [get_pblocks pblock_rp] [get_cells u_rp]
resize_pblock [get_pblocks pblock_rp] -add {SLICE_X58Y160:SLICE_X71Y189}
resize_pblock [get_pblocks pblock_rp] -add {RAMB18_X1Y64:RAMB18_X1Y75}
resize_pblock [get_pblocks pblock_rp] -add {RAMB36_X1Y32:RAMB36_X1Y37}
set_property SNAPPING_MODE ON [get_pblocks pblock_rp]
set_property CONTAIN_ROUTING 1 [get_pblocks pblock_rp]
set_property HD.RECONFIGURABLE 1 [get_cells u_rp]
