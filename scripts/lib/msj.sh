#!/bin/bash
# Generation of Desmond .msj/.cfg files.
# Scientific parameters are copied from the validated run_pipeline.sh
# (prepwizard -> system build -> min -> 5-stage NPT relaxation -> production).
# The GPU-side pl_analysis stage is intentionally omitted; analysis is done
# on CPU in 50_analysis.sh.

write_setup_msj() {
    local file="$1"
    cat > "$file" <<MSJEOF
task {
  task = "desmond:auto"
}

build_geometry {
  add_counterion = {
     ion = Na
     number = neutralize_system
  }
  box = {
     shape = orthorhombic
     size = [${BUFFER_SIZE} ${BUFFER_SIZE} ${BUFFER_SIZE}]
     size_type = buffer
  }
  override_forcefield = ${FORCEFIELD}
  rezero_system = false
  salt = {
     concentration = ${SALT_CONC}
     negative_ion = Cl
     positive_ion = Na
  }
  solvent = ${SOLVENT}
}

assign_forcefield {
  forcefield = ${FORCEFIELD}
}
MSJEOF
}

write_min_cfg() {
    local file="$1"
    cat > "$file" <<CFGEOF
backend = {}
bigger_rclone = false
box = ?
checkpt = {
   first = 0.0
   interval = 240.06
   name = "\$JOBNAME.cpt"
   write_last_step = true
}
cpu = 1
cutoff_radius = ${MD_CUTOFF}
energy_group = false
eneseq = {
   first = 0.0
   interval = 1.2
   name = "\$JOBNAME\$[_replica\$REPLICA\$].ene"
}
ensemble = {
   brownie = { delta_max = 0.1 }
   class = NVT
   method = Brownie
   thermostat = { tau = 1.0 }
}
glue = solute
maeff_output = {
   center_atoms = solute
   first = inf
   interval = 120.0
   name = "\$JOBNAME-out.cms"
   periodicfix = true
   trjdir = "\$JOBNAME\$[_replica\$REPLICA\$]_trj"
}
randomize_velocity = {
   first = 0.0
   interval = inf
   seed = ${MIN_SEED}
   temperature = "@*.temperature"
}
restrain = none
simbox = {}
taper = false
temperature = [[10.0 0]]
time = 100.0
timestep = [0.001 0.001 0.003]
trajectory = {
   center = []
   first = 0.0
   format = dtr
   frames_per_file = 250
   interval = 4.8
   name = "\$JOBNAME\$[_replica\$REPLICA\$]_trj"
   periodicfix = true
   write_last_vel = false
   write_velocity = false
}
CFGEOF
}

write_min_msj() {
    local file="$1"
    local cfg_basename="$2"
    cat > "$file" <<MSJEOF
task {
   task = "desmond:auto"
   set_family = { desmond = { checkpt.write_last_step = true } }
}

simulate {
   title       = "Brownian Dynamics NVT, T=10K, solute heavy atom restraints, 100ps"
   annealing   = off
   time        = 100
   timestep    = [0.001 0.001 0.003]
   temperature = 10.0
   ensemble = {
      class = "NVT"
      method = "Brownie"
      brownie = { delta_max = 0.1 }
   }
   restrain = { atom = "solute_heavy_atom" force_constant = 50.0 }
}

simulate {
   cfg_file = "${cfg_basename}"
   jobname  = "\$MASTERJOBNAME"
   dir      = "."
   compress = ""
}
MSJEOF
}

write_md_cfg() {
    local file="$1"
    cat > "$file" <<CFGEOF
annealing = false
backend = {}
bigger_rclone = false
box = ?
checkpt = {
   first = 0.0
   interval = 240.06
   name = "\$JOBNAME.cpt"
   write_last_step = true
}
cpu = 1
cutoff_radius = ${MD_CUTOFF}
elapsed_time = 0.0
energy_group = false
eneseq = {
   first = 0.0
   interval = 1.2
   name = "\$JOBNAME\$[_replica\$REPLICA\$].ene"
}
ensemble = {
   barostat = { tau = 2.0 }
   class = NPT
   method = MTK
   thermostat = { tau = 1.0 }
}
glue = solute
maeff_output = {
   center_atoms = solute
   first = 0.0
   interval = 120.0
   name = "\$JOBNAME\$[_replica\$REPLICA\$]-out.cms"
   periodicfix = true
   trjdir = "\$JOBNAME\$[_replica\$REPLICA\$]_trj"
}
meta = false
meta_file = ?
pressure = [1.01325 isotropic]
randomize_velocity = {
   first = 0.0
   interval = inf
   seed = ${MD_SEED}
   temperature = "@*.temperature"
}
restrain = none
simbox = {
   first = 0.0
   interval = 1.2
   name = "\$JOBNAME\$[_replica\$REPLICA\$]_simbox.dat"
}
surface_tension = 0.0
taper = false
temperature = [[${MD_TEMPERATURE} 0]]
time = ${MD_TIME_PS}
timestep = [0.002 0.002 0.006]
trajectory = {
   center = []
   first = 0.0
   format = dtr
   frames_per_file = 250
   interval = ${MD_TRAJ_INTERVAL_PS}
   name = "\$JOBNAME\$[_replica\$REPLICA\$]_trj"
   periodicfix = true
   write_last_vel = false
   write_velocity = false
}
CFGEOF
}

write_md_msj() {
    local file="$1"
    local cfg_basename="$2"
    cat > "$file" <<MSJEOF
# Desmond standard NPT relaxation protocol.
# pl_analysis is deliberately omitted: trajectory analysis is done on CPU.
task {
   task = "desmond:auto"
   set_family = { desmond = { checkpt.write_last_step = true } }
}

simulate {
   title       = "Brownian Dynamics NVT, T=10K, small timesteps, solute heavy atom restraints, 100ps"
   annealing   = off
   time        = 100
   timestep    = [0.001 0.001 0.003]
   temperature = 10.0
   ensemble = {
      class = "NVT"
      method = "Brownie"
      brownie = { delta_max = 0.1 }
   }
   restrain = { atom = "solute_heavy_atom" force_constant = 50.0 }
}

simulate {
   title       = "NVT, T=10K, small timesteps, solute heavy atom restraints, 12ps"
   annealing   = off
   time        = 12
   timestep    = [0.001 0.001 0.003]
   temperature = 10.0
   restrain    = { atom = solute_heavy_atom force_constant = 50.0 }
   ensemble    = {
      class  = NVT
      method = Langevin
      thermostat.tau = 0.1
   }
   randomize_velocity.interval = 1.0
   eneseq.interval             = 0.3
   trajectory.center           = []
}

simulate {
   title       = "NPT, T=10K, solute heavy atom restraints, 12ps"
   annealing   = off
   time        = 12
   temperature = 10.0
   restrain    = retain
   ensemble    = {
      class  = NPT
      method = Langevin
      thermostat.tau = 0.1
      barostat  .tau = 50.0
   }
   randomize_velocity.interval = 1.0
   eneseq.interval             = 0.3
   trajectory.center           = []
}

simulate {
   title       = "NPT, solute heavy atom restraints, 12ps"
   effect_if   = [["@*.*.annealing"] 'annealing = off temperature = "@*.*.temperature[0][0]"']
   time        = 12
   restrain    = retain
   ensemble    = {
      class  = NPT
      method = Langevin
      thermostat.tau = 0.1
      barostat  .tau = 50.0
   }
   randomize_velocity.interval = 1.0
   eneseq.interval             = 0.3
   trajectory.center           = []
}

simulate {
   title       = "NPT, no restraints, 24ps"
   effect_if   = [["@*.*.annealing"] 'annealing = off temperature = "@*.*.temperature[0][0]"']
   time        = 24
   ensemble    = {
      class  = NPT
      method = Langevin
      thermostat.tau = 0.1
      barostat  .tau = 2.0
   }
   eneseq.interval   = 0.3
   trajectory.center = solute
}

simulate {
   cfg_file = "${cfg_basename}"
   jobname  = "\$MASTERJOBNAME"
   dir      = "."
   compress = ""
}
MSJEOF
}
