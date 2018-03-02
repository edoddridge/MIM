!> @author
!> Ed Doddridge
!
!> Aronnax, an idealized isopycnal model with n layers and variable bathymetry.
!!
!
!>
!>     @mainpage Documentation for aronnax.f90
!>
!>     @section Overview
!>     This model is an isopycnal model on an Arakawa C-grid with n
!>     layers and arbitrary bathymetry.
!>
!>
!>
!>    @section Grid
!>
!>    /\ ------------
!>    |  |          |
!>    |  |          |
!>    dy U    H     |
!>    |  |          |
!>    |  |          |
!>    \/ Z----V------
!>        <---dx---->
!>
!>    H: tracer point - thickness, Bernoulli potential
!>    U: velocity point - u and v
!>    Z: vorticity point - zeta
!>


program aronnax
  implicit none

  include 'mpif.h'

  integer, parameter :: layerwise_input_length = 10000
  ! Resolution
  integer :: nx !< number of x grid points
  integer :: ny !< number of y grid points
  integer :: layers !< number of active layers in the model
  ! Layer thickness (h)
  double precision, dimension(:,:,:), allocatable :: h
  ! Velocity component (u)
  double precision, dimension(:,:,:), allocatable :: u
  ! Velocity component (v)
  double precision, dimension(:,:,:), allocatable :: v
  ! Free surface (eta)
  double precision, dimension(:,:),   allocatable :: eta
  ! Bathymetry
  character(60) :: depthFile
  double precision, dimension(:,:),   allocatable :: depth
  double precision :: H0 ! default depth in no file specified
  ! Grid
  double precision :: dx, dy
  double precision, dimension(:,:),   allocatable :: wetmask
  ! Coriolis parameter at u and v grid-points respectively
  double precision, dimension(:,:),   allocatable :: fu
  double precision, dimension(:,:),   allocatable :: fv
  ! File names to read them from
  character(60) :: fUfile, fVfile
  character(60) :: wetMaskFile
  ! Numerics
  double precision :: dt
  double precision :: au, ar, botDrag
  double precision :: kh(layerwise_input_length), kv
  double precision :: slip, hmin
  integer          :: niter0, nTimeSteps
  double precision :: dumpFreq, avFreq, checkpointFreq, diagFreq
  double precision, dimension(:),     allocatable :: zeros
  integer maxits
  double precision :: eps, freesurfFac, thickness_error
  integer          :: debug_level
  ! Model
  double precision :: hmean(layerwise_input_length)
  ! Switch for using n + 1/2 layer physics, or using n layer physics
  logical :: RedGrav
  ! Physics
  double precision :: g_vec(layerwise_input_length)
  double precision :: rho0
  ! Wind
  double precision, dimension(:,:),   allocatable :: base_wind_x
  double precision, dimension(:,:),   allocatable :: base_wind_y
  logical :: DumpWind
  character(60) :: wind_mag_time_series_file
  double precision, dimension(:),     allocatable :: wind_mag_time_series
  ! Sponge regions
  double precision, dimension(:,:,:), allocatable :: spongeHTimeScale
  double precision, dimension(:,:,:), allocatable :: spongeUTimeScale
  double precision, dimension(:,:,:), allocatable :: spongeVTimeScale
  double precision, dimension(:,:,:), allocatable :: spongeH
  double precision, dimension(:,:,:), allocatable :: spongeU
  double precision, dimension(:,:,:), allocatable :: spongeV
  character(60) :: spongeHTimeScaleFile
  character(60) :: spongeUTimeScaleFile
  character(60) :: spongeVTimeScaleFile
  character(60) :: spongeHfile
  character(60) :: spongeUfile
  character(60) :: spongeVfile
  ! Main input files
  character(60) :: initUfile, initVfile, initHfile, initEtaFile
  character(60) :: zonalWindFile, meridionalWindFile
  logical :: RelativeWind
  double precision :: Cd

  ! External pressure solver variables
  integer :: nProcX, nProcY


  integer :: ierr
  integer :: num_procs, myid

  integer, dimension(:,:), allocatable :: ilower, iupper
  integer, dimension(:,:), allocatable :: jlower, jupper
  integer*8 :: hypre_grid
  integer :: i, j
  integer   :: offsets(2,5)




  ! TODO Possibly wait until the model is split into multiple files,
  ! then hide the long unsightly code there.

  namelist /NUMERICS/ au, kh, kv, ar, botDrag, dt, slip, &
      niter0, nTimeSteps, &
      dumpFreq, avFreq, checkpointFreq, diagFreq, hmin, maxits, & 
      freesurfFac, eps, thickness_error, debug_level

  namelist /MODEL/ hmean, depthFile, H0, RedGrav

  namelist /PRESSURE_SOLVER/ nProcX, nProcY

  namelist /SPONGE/ spongeHTimeScaleFile, spongeUTimeScaleFile, &
      spongeVTimeScaleFile, spongeHfile, spongeUfile, spongeVfile

  namelist /PHYSICS/ g_vec, rho0

  namelist /GRID/ nx, ny, layers, dx, dy, fUfile, fVfile, wetMaskFile

  namelist /INITIAL_CONDITIONS/ initUfile, initVfile, initHfile, initEtaFile

  namelist /EXTERNAL_FORCING/ zonalWindFile, meridionalWindFile, &
      RelativeWind, Cd, &
      DumpWind, wind_mag_time_series_file

  ! Set default values here
  dumpFreq = 0d0
  avFreq = 0d0
  checkpointFreq = 0d0
  diagFreq = 0d0
  debug_level = 0
  niter0 = 0
  RelativeWind = .FALSE.

  au = 0d0
  ar = 0d0
  kh = 0d0
  kv = 0d0

  
  open(unit=8, file="parameters.in", status='OLD', recl=80)
  read(unit=8, nml=NUMERICS)
  read(unit=8, nml=MODEL)
  read(unit=8, nml=PRESSURE_SOLVER)
  read(unit=8, nml=SPONGE)
  read(unit=8, nml=PHYSICS)
  read(unit=8, nml=GRID)
  read(unit=8, nml=INITIAL_CONDITIONS)
  read(unit=8, nml=EXTERNAL_FORCING)
  close(unit=8)


  ! optionally include the MPI code for parallel runs with external
  ! pressure solver
  call MPI_INIT(ierr)
  call MPI_COMM_RANK(MPI_COMM_WORLD, myid, ierr)
  call MPI_COMM_SIZE(MPI_COMM_WORLD, num_procs, ierr)
  ! mpi_comm = MPI_COMM_WORLD

  if (num_procs .ne. nProcX * nProcY) then
    if (myid .eq. 0) then
       write(17, "(A)") "number of processors in run command must equal nProcX * nProcY - fix this and try again"
       write(17, "(A, I0)") 'num_procs = ', num_procs
       write(17, "(A, I0)") 'nProcX = ', nProcX
       write(17, "(A, I0)") 'nProcY = ', nProcY
    end if
    call clean_stop(0, .FALSE.)
  end if

  ! myid starts at zero, so index these variables from zero.
  ! i__(:,1) = indicies for x locations
  ! i__(:,2) = indicies for y locations
  allocate(ilower(0:num_procs-1, 2))
  allocate(iupper(0:num_procs-1, 2))


  do i = 0, nProcX - 1
    ilower(i * nProcY:(i+1)*nProcY - 1,1) = i * nx / nProcX
    iupper(i * nProcY:(i+1)*nProcY - 1,1) = ((i+1) * nx / nProcX)
  end do
  ! correct first ilower value to exclude the global halo
  ilower(0,1) = 1

  do j = 0, nProcY - 1
    ilower(j * nProcX:(j+1)*nProcX - 1,2) = j * ny / nProcY
    iupper(j * nProcX:(j+1)*nProcX - 1,2) = ((j+1) * ny / nProcY)
  end do
  ! correct first ilower value to exclude the global halo
  ilower(0,2) = 1

#ifdef useExtSolver
  call create_Hypre_grid(MPI_COMM_WORLD, hypre_grid, ilower, iupper, &
          num_procs, myid, nx, ny, ierr)
#endif



  allocate(h(0:nx+1, 0:ny+1, layers))
  allocate(u(0:nx+1, 0:ny+1, layers))
  allocate(v(0:nx+1, 0:ny+1, layers))
  allocate(eta(0:nx+1, 0:ny+1))
  allocate(depth(0:nx+1, 0:ny+1))

  allocate(wetmask(0:nx+1, 0:ny+1))
  allocate(fu(0:nx+1, 0:ny+1))
  allocate(fv(0:nx+1, 0:ny+1))

  allocate(zeros(layers))

  allocate(base_wind_x(0:nx+1, 0:ny+1))
  allocate(base_wind_y(0:nx+1, 0:ny+1))
  allocate(wind_mag_time_series(nTimeSteps))

  allocate(spongeHTimeScale(0:nx+1, 0:ny+1, layers))
  allocate(spongeUTimeScale(0:nx+1, 0:ny+1, layers))
  allocate(spongeVTimeScale(0:nx+1, 0:ny+1, layers))
  allocate(spongeH(0:nx+1, 0:ny+1, layers))
  allocate(spongeU(0:nx+1, 0:ny+1, layers))
  allocate(spongeV(0:nx+1, 0:ny+1, layers))

  ! Zero vector - for internal use only
  zeros = 0d0


  ! Read in arrays from the input files
  call read_input_fileU(initUfile, u, 0.d0, nx, ny, layers)
  call read_input_fileV(initVfile, v, 0.d0, nx, ny, layers)
  call read_input_fileH(initHfile, h, hmean, nx, ny, layers)

  call read_input_fileU(fUfile, fu, 0.d0, nx, ny, 1)
  call read_input_fileV(fVfile, fv, 0.d0, nx, ny, 1)

  call read_input_fileU(zonalWindFile, base_wind_x, 0.d0, nx, ny, 1)
  call read_input_fileV(meridionalWindFile, base_wind_y, 0.d0, nx, ny, 1)

  call read_input_file_time_series(wind_mag_time_series_file, &
      wind_mag_time_series, 1d0, nTimeSteps)

  call read_input_fileH(spongeHTimeScaleFile, spongeHTimeScale, &
      zeros, nx, ny, layers)
  call read_input_fileH(spongeHfile, spongeH, hmean, nx, ny, layers)
  call read_input_fileU(spongeUTimeScaleFile, spongeUTimeScale, &
      0.d0, nx, ny, layers)
  call read_input_fileU(spongeUfile, spongeU, 0.d0, nx, ny, layers)
  call read_input_fileV(spongeVTimeScaleFile, spongeVTimeScale, &
      0.d0, nx, ny, layers)
  call read_input_fileV(spongeVfile, spongeV, 0.d0, nx, ny, layers)
  call read_input_fileH_2D(wetMaskFile, wetmask, 1.d0, nx, ny)

  if (.not. RedGrav) then
    call read_input_fileH_2D(depthFile, depth, H0, nx, ny)
    call read_input_fileH_2D(initEtaFile, eta, 0.d0, nx, ny)
    ! Check that depth is positive - it must be greater than zero
    if (minval(depth) .lt. 0) then
      write(17, "(A)") "Depths must be positive."
      call clean_stop(0, .FALSE.)
    end if
  end if


  call model_run(h, u, v, eta, depth, dx, dy, wetmask, fu, fv, &
      dt, au, ar, botDrag, kh, kv, slip, hmin, niter0, nTimeSteps, &
      dumpFreq, avFreq, checkpointFreq, diagFreq, &
      maxits, eps, freesurfFac, thickness_error, &
      debug_level, g_vec, rho0, &
      base_wind_x, base_wind_y, wind_mag_time_series, &
      spongeHTimeScale, spongeUTimeScale, spongeVTimeScale, &
      spongeH, spongeU, spongeV, &
      nx, ny, layers, RedGrav, DumpWind, &
      RelativeWind, Cd, &
      MPI_COMM_WORLD, myid, num_procs, ilower, iupper, &
      hypre_grid)

  ! Finalize MPI
  call clean_stop(nTimeSteps, .TRUE.)
end program aronnax

! ------------------------------ Primary routine ----------------------------
!> Run the model

subroutine model_run(h, u, v, eta, depth, dx, dy, wetmask, fu, fv, &
    dt, au, ar, botDrag, kh, kv, slip, hmin, niter0, nTimeSteps, &
    dumpFreq, avFreq, checkpointFreq, diagFreq, &
    maxits, eps, freesurfFac, thickness_error, &
    debug_level, g_vec, rho0, &
    base_wind_x, base_wind_y, wind_mag_time_series, &
    spongeHTimeScale, spongeUTimeScale, spongeVTimeScale, &
    spongeH, spongeU, spongeV, &
    nx, ny, layers, RedGrav, DumpWind, &
    RelativeWind, Cd, &
    MPI_COMM_WORLD, myid, num_procs, ilower, iupper, &
    hypre_grid)
  implicit none

  ! Layer thickness (h)
  double precision, intent(inout) :: h(0:nx+1, 0:ny+1, layers)
  ! Velocity component (u)
  double precision, intent(inout) :: u(0:nx+1, 0:ny+1, layers)
  ! Velocity component (v)
  double precision, intent(inout) :: v(0:nx+1, 0:ny+1, layers)
  ! Free surface (eta)
  double precision, intent(inout) :: eta(0:nx+1, 0:ny+1)
  ! Bathymetry
  double precision, intent(in) :: depth(0:nx+1, 0:ny+1)
  ! Grid
  double precision, intent(in) :: dx, dy
  double precision, intent(in) :: wetmask(0:nx+1, 0:ny+1)
  ! Coriolis parameter at u and v grid-points respectively
  double precision, intent(in) :: fu(0:nx+1, 0:ny+1)
  double precision, intent(in) :: fv(0:nx+1, 0:ny+1)
  ! Numerics
  double precision, intent(in) :: dt, au, ar, botDrag
  double precision, intent(in) :: kh(layers), kv
  double precision, intent(in) :: slip, hmin
  integer,          intent(in) :: niter0, nTimeSteps
  double precision, intent(in) :: dumpFreq, avFreq, checkpointFreq, diagFreq
  integer,          intent(in) :: maxits
  double precision, intent(in) :: eps, freesurfFac, thickness_error
  integer,          intent(in) :: debug_level
  ! Physics
  double precision, intent(in) :: g_vec(layers)
  double precision, intent(in) :: rho0
  ! Wind
  double precision, intent(in) :: base_wind_x(0:nx+1, 0:ny+1)
  double precision, intent(in) :: base_wind_y(0:nx+1, 0:ny+1)
  double precision, intent(in) :: wind_mag_time_series(nTimeSteps)
  ! Sponge regions
  double precision, intent(in) :: spongeHTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeUTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeVTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeH(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeU(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeV(0:nx+1, 0:ny+1, layers)
  ! Resolution
  integer,          intent(in) :: nx, ny, layers
  ! Reduced gravity vs n-layer physics
  logical,          intent(in) :: RedGrav
  ! Whether to write computed wind in the output
  logical,          intent(in) :: DumpWind
  logical,          intent(in) :: RelativeWind
  double precision,  intent(in) :: Cd

  double precision :: dhdt(0:nx+1, 0:ny+1, layers)
  double precision :: dhdtold(0:nx+1, 0:ny+1, layers)
  double precision :: dhdtveryold(0:nx+1, 0:ny+1, layers)
  double precision :: hnew(0:nx+1, 0:ny+1, layers)
  ! for initialisation
  double precision :: hhalf(0:nx+1, 0:ny+1, layers)
  ! for saving average fields
  double precision :: hav(0:nx+1, 0:ny+1, layers)

  double precision :: dudt(0:nx+1, 0:ny+1, layers)
  double precision :: dudtold(0:nx+1, 0:ny+1, layers)
  double precision :: dudtveryold(0:nx+1, 0:ny+1, layers)
  double precision :: unew(0:nx+1, 0:ny+1, layers)
  ! for initialisation
  double precision :: uhalf(0:nx+1, 0:ny+1, layers)
  ! for saving average fields
  double precision :: uav(0:nx+1, 0:ny+1, layers)

  double precision :: dvdt(0:nx+1, 0:ny+1, layers)
  double precision :: dvdtold(0:nx+1, 0:ny+1, layers)
  double precision :: dvdtveryold(0:nx+1, 0:ny+1, layers)
  double precision :: vnew(0:nx+1, 0:ny+1, layers)
  ! for initialisation
  double precision :: vhalf(0:nx+1, 0:ny+1, layers)
  ! for saving average fields
  double precision :: vav(0:nx+1, 0:ny+1, layers)

  double precision :: etanew(0:nx+1, 0:ny+1)
  ! for saving average fields
  double precision :: etaav(0:nx+1, 0:ny+1)

  ! Pressure solver variables
  double precision :: a(5, nx, ny)

  ! Geometry
  double precision :: hfacW(0:nx+1, 0:ny+1)
  double precision :: hfacE(0:nx+1, 0:ny+1)
  double precision :: hfacN(0:nx+1, 0:ny+1)
  double precision :: hfacS(0:nx+1, 0:ny+1)

  ! Numerics
  double precision :: pi
  double precision :: rjac

  ! dumping output
  integer :: nwrite, avwrite, checkpointwrite, diagwrite

  ! External solver variables
  integer          :: offsets(2,5)
  integer          :: i, j ! loop variables
  double precision :: values(nx * ny)
  integer          :: indicies(2)
  integer*8        :: hypre_grid
  integer*8        :: stencil
  integer*8        :: hypre_A
  integer          :: ilower(0:num_procs-1,2), iupper(0:num_procs-1,2)
  integer          :: ierr
  integer          :: MPI_COMM_WORLD
  integer          :: myid
  integer          :: num_procs

  ! Time step loop variable
  integer :: n

  ! Wind
  double precision :: wind_x(0:nx+1, 0:ny+1)
  double precision :: wind_y(0:nx+1, 0:ny+1)

  ! Time
  integer*8 :: start_time, last_report_time, cur_time

  ! dummy variable for loading checkpoints
  character(10)    :: num


  start_time = time()
  if (RedGrav) then
    print "(A, I0, A, I0, A, I0, A, I0, A)", &
        "Running a reduced-gravity configuration of size ", &
        nx, "x", ny, "x", layers, " by ", nTimeSteps, " time steps."
  else
    print "(A, I0, A, I0, A, I0, A, I0, A)", &
        "Running an n-layer configuration of size ", &
        nx, "x", ny, "x", layers, " by ", nTimeSteps, " time steps."
  end if

  if (myid .eq. 0) then
    ! Show the domain decomposition
    print "(A)", "Domain decomposition:"
    print "(A, I0)", 'ilower (x) = ', ilower(:,1)
    print "(A, I0)", 'ilower (y) = ', ilower(:,2)
    print "(A, I0)", 'iupper (x) = ', iupper(:,1)
    print "(A, I0)", 'iupper (y) = ', iupper(:,2)
  end if

  last_report_time = start_time

  nwrite = int(dumpFreq/dt)
  avwrite = int(avFreq/dt)
  checkpointwrite = int(checkpointFreq/dt)
  diagwrite = int(diagFreq/dt)

  ! Pi, the constant
  pi = 3.1415926535897932384

  ! Initialize wind fields
  wind_x = base_wind_x*wind_mag_time_series(1)
  wind_y = base_wind_y*wind_mag_time_series(1)

  ! Initialise the diagnostic files
  call create_diag_file(layers, 'output/diagnostic.h.csv', 'h', niter0)
  call create_diag_file(layers, 'output/diagnostic.u.csv', 'u', niter0)
  call create_diag_file(layers, 'output/diagnostic.v.csv', 'v', niter0)
  if (.not. RedGrav) then
    call create_diag_file(1, 'output/diagnostic.eta.csv', 'eta', niter0)
  end if

  ! Initialise the average fields
  if (avwrite .ne. 0) then
    hav = 0.0
    uav = 0.0
    vav = 0.0
    if (.not. RedGrav) then
      etaav = 0.0
    end if
  end if

  ! initialise etanew
  etanew = 0d0

  call calc_boundary_masks(wetmask, hfacW, hfacE, hfacS, hfacN, nx, ny)

  call apply_boundary_conditions(u, hfacW, wetmask, nx, ny, layers)
  call apply_boundary_conditions(v, hfacS, wetmask, nx, ny, layers)


  if (.not. RedGrav) then
    ! Initialise arrays for pressure solver
    ! a = derivatives of the depth field
      call calc_A_matrix(a, depth, g_vec(1), dx, dy, nx, ny, freesurfFac, dt, &
          hfacW, hfacE, hfacS, hfacN)

#ifndef useExtSolver
    ! Calculate the spectral radius of the grid for use by the
    ! successive over-relaxation scheme
    rjac = (cos(pi/real(nx))*dy**2+cos(pi/real(ny))*dx**2) &
           /(dx**2+dy**2)
    ! If peridodic boundary conditions are ever implemented, then pi ->
    ! 2*pi in this calculation
#else
    ! use the external pressure solver
    call create_Hypre_A_matrix(MPI_COMM_WORLD, hypre_grid, hypre_A, &
          a, nx, ny, ierr)
#endif

    ! Check that the supplied free surface anomaly and layer
    ! thicknesses are consistent with the supplied depth field.
    ! If they are not, then scale the layer thicknesses to make
    ! them consistent.
    call enforce_depth_thickness_consistency(h, eta, depth, &
        freesurfFac, thickness_error, nx, ny, layers)
  end if

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !!!  Initialisation of the model STARTS HERE                            !!!
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  if (niter0 .eq. 0) then
    ! Do two initial time steps with Runge-Kutta second-order.
    ! These initialisation steps do NOT use or update the free surface.
    !
    ! ------------------------- negative 2 time step --------------------------
    ! Code to work out dhdtveryold, dudtveryold and dvdtveryold
    n = 0
    
    call state_derivative(dhdtveryold, dudtveryold, dvdtveryold, &
        h, u, v, depth, &
        dx, dy, wetmask, hfacW, hfacE, hfacN, hfacS, fu, fv, &
        au, ar, botDrag, kh, kv, slip, &
        RedGrav, g_vec, rho0, wind_x, wind_y, &
        RelativeWind, Cd, &
        spongeHTimeScale, spongeH, &
        spongeUTimeScale, spongeU, &
        spongeVTimeScale, spongeV, &
        nx, ny, layers, n, debug_level)

    ! Calculate the values at half the time interval with Forward Euler
    hhalf = h+0.5d0*dt*dhdtveryold
    uhalf = u+0.5d0*dt*dudtveryold
    vhalf = v+0.5d0*dt*dvdtveryold

    call state_derivative(dhdtveryold, dudtveryold, dvdtveryold, &
        hhalf, uhalf, vhalf, depth, &
        dx, dy, wetmask, hfacW, hfacE, hfacN, hfacS, fu, fv, &
        au, ar, botDrag, kh, kv, slip, &
        RedGrav, g_vec, rho0, wind_x, wind_y, &
        RelativeWind, Cd, &
        spongeHTimeScale, spongeH, &
        spongeUTimeScale, spongeU, &
        spongeVTimeScale, spongeV, &
        nx, ny, layers, n, debug_level)

    ! These are the values to be stored in the 'veryold' variables ready
    ! to start the proper model run.

    ! Calculate h, u, v with these tendencies
    h = h + dt*dhdtveryold
    u = u + dt*dudtveryold
    v = v + dt*dvdtveryold

    ! Apply the boundary conditions
    call apply_boundary_conditions(u, hfacW, wetmask, nx, ny, layers)
    call apply_boundary_conditions(v, hfacS, wetmask, nx, ny, layers)

    ! Wrap fields around for periodic simulations
    call wrap_fields_3D(u, nx, ny, layers)
    call wrap_fields_3D(v, nx, ny, layers)
    call wrap_fields_3D(h, nx, ny, layers)

    ! ------------------------- negative 1 time step --------------------------
    ! Code to work out dhdtold, dudtold and dvdtold

    call state_derivative(dhdtold, dudtold, dvdtold, &
        h, u, v, depth, &
        dx, dy, wetmask, hfacW, hfacE, hfacN, hfacS, fu, fv, &
        au, ar, botDrag, kh, kv, slip, &
        RedGrav, g_vec, rho0, wind_x, wind_y, &
        RelativeWind, Cd, &
        spongeHTimeScale, spongeH, &
        spongeUTimeScale, spongeU, &
        spongeVTimeScale, spongeV, &
        nx, ny, layers, n, debug_level)

    ! Calculate the values at half the time interval with Forward Euler
    hhalf = h+0.5d0*dt*dhdtold
    uhalf = u+0.5d0*dt*dudtold
    vhalf = v+0.5d0*dt*dvdtold

    call state_derivative(dhdtold, dudtold, dvdtold, &
        hhalf, uhalf, vhalf, depth, &
        dx, dy, wetmask, hfacW, hfacE, hfacN, hfacS, fu, fv, &
        au, ar, botDrag, kh, kv, slip, &
        RedGrav, g_vec, rho0, wind_x, wind_y, &
        RelativeWind, Cd, &
        spongeHTimeScale, spongeH, &
        spongeUTimeScale, spongeU, &
        spongeVTimeScale, spongeV, &
        nx, ny, layers, n, debug_level)

    ! These are the values to be stored in the 'old' variables ready to start
    ! the proper model run.

    ! Calculate h, u, v with these tendencies
    h = h + dt*dhdtold
    u = u + dt*dudtold
    v = v + dt*dvdtold

    ! Apply the boundary conditions
    call apply_boundary_conditions(u, hfacW, wetmask, nx, ny, layers)
    call apply_boundary_conditions(v, hfacS, wetmask, nx, ny, layers)

    ! Wrap fields around for periodic simulations
    call wrap_fields_3D(u, nx, ny, layers)
    call wrap_fields_3D(v, nx, ny, layers)
    call wrap_fields_3D(h, nx, ny, layers)

  else if (niter0 .ne. 0) then
    n = niter0

    ! load in the state and derivative arrays
    write(num, '(i10.10)') niter0

    open(unit=10, form='unformatted', file='checkpoints/h.'//num)
    read(10) h
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/u.'//num)
    read(10) u
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/v.'//num)
    read(10) v
    close(10)

    open(unit=10, form='unformatted', file='checkpoints/dhdt.'//num)
    read(10) dhdt
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/dudt.'//num)
    read(10) dudt
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/dvdt.'//num)
    read(10) dvdt
    close(10)

    open(unit=10, form='unformatted', file='checkpoints/dhdtold.'//num)
    read(10) dhdtold
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/dudtold.'//num)
    read(10) dudtold
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/dvdtold.'//num)
    read(10) dvdtold
    close(10)

    open(unit=10, form='unformatted', file='checkpoints/dhdtveryold.'//num)
    read(10) dhdtveryold
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/dudtveryold.'//num)
    read(10) dudtveryold
    close(10)
    open(unit=10, form='unformatted', file='checkpoints/dvdtveryold.'//num)
    read(10) dvdtveryold
    close(10)

    if (.not. RedGrav) then
      open(unit=10, form='unformatted', file='checkpoints/eta.'//num)
      read(10) eta
      close(10)
    end if

  end if

  ! Now the model is ready to start.
  ! - We have h, u, v at the zeroth time step, and the tendencies at
  !   two older time steps.
  ! - The model then solves for the tendencies at the current step
  !   before solving for the fields at the next time step.

  cur_time = time()
  if (cur_time - start_time .eq. 1) then
    print "(A)", "Initialized in 1 second."
  else
    print "(A, I0, A)", "Initialized in " , cur_time - start_time, " seconds."
  end if
  last_report_time = cur_time

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !!! MAIN LOOP OF THE MODEL STARTS HERE                                  !!!
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  do n = niter0+1, niter0+nTimeSteps

    wind_x = base_wind_x*wind_mag_time_series(n-niter0)
    wind_y = base_wind_y*wind_mag_time_series(n-niter0)

    call state_derivative(dhdt, dudt, dvdt, h, u, v, depth, &
        dx, dy, wetmask, hfacW, hfacE, hfacN, hfacS, fu, fv, &
        au, ar, botDrag, kh, kv, slip, &
        RedGrav, g_vec, rho0, wind_x, wind_y, &
        RelativeWind, Cd, &
        spongeHTimeScale, spongeH, &
        spongeUTimeScale, spongeU, &
        spongeVTimeScale, spongeV, &
        nx, ny, layers, n, debug_level)


    ! Use dh/dt, du/dt and dv/dt to step h, u and v forward in time with
    ! the Adams-Bashforth third order linear multistep method

    unew = u + dt*(23d0*dudt - 16d0*dudtold + 5d0*dudtveryold)/12d0
    vnew = v + dt*(23d0*dvdt - 16d0*dvdtold + 5d0*dvdtveryold)/12d0
    hnew = h + dt*(23d0*dhdt - 16d0*dhdtold + 5d0*dhdtveryold)/12d0

    ! Apply the boundary conditions
    call apply_boundary_conditions(unew, hfacW, wetmask, nx, ny, layers)
    call apply_boundary_conditions(vnew, hfacS, wetmask, nx, ny, layers)

    ! Do the isopycnal layer physics
    if (.not. RedGrav) then
      call barotropic_correction(hnew, unew, vnew, eta, etanew, depth, a, &
          dx, dy, wetmask, hfacW, hfacS, dt, &
          maxits, eps, rjac, freesurfFac, thickness_error, &
          debug_level, g_vec, nx, ny, layers, n, &
          MPI_COMM_WORLD, myid, num_procs, ilower, iupper, &
          hypre_grid, hypre_A, ierr)

    end if


    ! Stop layers from getting too thin
    call enforce_minimum_layer_thickness(hnew, hmin, nx, ny, layers, n)

    ! Wrap fields around for periodic simulations
    call wrap_fields_3D(unew, nx, ny, layers)
    call wrap_fields_3D(vnew, nx, ny, layers)
    call wrap_fields_3D(hnew, nx, ny, layers)
    if (.not. RedGrav) then
      call wrap_fields_2D(etanew, nx, ny)
    end if    

    ! Accumulate average fields
    if (avwrite .ne. 0) then
      hav = hav + hnew
      uav = uav + unew
      vav = vav + vnew
      if (.not. RedGrav) then
        etaav = eta + etanew
      end if
    end if

    ! Shuffle arrays: old -> very old,  present -> old, new -> present
    ! Height and velocity fields
    h = hnew
    u = unew
    v = vnew
    if (.not. RedGrav) then
      eta = etanew
    end if

    ! Tendencies (old -> very old)
    dhdtveryold = dhdtold
    dudtveryold = dudtold
    dvdtveryold = dvdtold

    ! Tendencies (current -> old)
    dudtold = dudt
    dvdtold = dvdt
    dhdtold = dhdt

    ! Now have new fields in main arrays and old fields in very old arrays

    call maybe_dump_output(h, hav, u, uav, v, vav, eta, etaav, &
        dudt, dvdt, dhdt, &
        dudtold, dvdtold, dhdtold, &
        dudtveryold, dvdtveryold, dhdtveryold, &
        wind_x, wind_y, nx, ny, layers, &
        n, nwrite, avwrite, checkpointwrite, diagwrite, &
        RedGrav, DumpWind, debug_level)


    cur_time = time()
    if (cur_time - last_report_time > 3) then
      ! Three seconds passed since last report
      last_report_time = cur_time
      print "(A, I0, A, I0, A)", "Completed time step ", &
          n, " at ", cur_time - start_time, " seconds."
    end if

  end do

  cur_time = time()
  print "(A, I0, A, I0, A)", "Run finished at time step ", &
      n, ", in ", cur_time - start_time, " seconds."

  ! save checkpoint at end of every simulation
  call maybe_dump_output(h, hav, u, uav, v, vav, eta, etaav, &
      dudt, dvdt, dhdt, &
      dudtold, dvdtold, dhdtold, &
      dudtveryold, dvdtveryold, dhdtveryold, &
      wind_x, wind_y, nx, ny, layers, &
      n, n, n, n-1, n, &
      RedGrav, DumpWind, 0)

  return
end subroutine model_run

! ----------------------------- Auxiliary routines --------------------------
!> Compute the forward state derivative

subroutine state_derivative(dhdt, dudt, dvdt, h, u, v, depth, &
    dx, dy, wetmask, hfacW, hfacE, hfacN, hfacS, fu, fv, &
    au, ar, botDrag, kh, kv, slip, &
    RedGrav, g_vec, rho0, wind_x, wind_y, &
    RelativeWind, Cd, &
    spongeHTimeScale, spongeH, &
    spongeUTimeScale, spongeU, &
    spongeVTimeScale, spongeV, &
    nx, ny, layers, n, debug_level)
  implicit none

  double precision, intent(out) :: dhdt(0:nx+1, 0:ny+1, layers)
  double precision, intent(out) :: dudt(0:nx+1, 0:ny+1, layers)
  double precision, intent(out) :: dvdt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: v(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: depth(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: dx, dy
  double precision, intent(in) :: wetmask(0:nx+1, 0:ny+1)
  double precision, intent(in) :: hfacW(0:nx+1, 0:ny+1)
  double precision, intent(in) :: hfacE(0:nx+1, 0:ny+1)
  double precision, intent(in) :: hfacN(0:nx+1, 0:ny+1)
  double precision, intent(in) :: hfacS(0:nx+1, 0:ny+1)
  double precision, intent(in) :: fu(0:nx+1, 0:ny+1)
  double precision, intent(in) :: fv(0:nx+1, 0:ny+1)
  double precision, intent(in) :: au, ar, botDrag
  double precision, intent(in) :: kh(layers), kv
  double precision, intent(in) :: slip
  logical,          intent(in) :: RedGrav
  double precision, intent(in) :: g_vec(layers)
  double precision, intent(in) :: rho0
  double precision, intent(in) :: wind_x(0:nx+1, 0:ny+1)
  double precision, intent(in) :: wind_y(0:nx+1, 0:ny+1)
  logical,          intent(in) :: RelativeWind
  double precision, intent(in) :: Cd
  double precision, intent(in) :: spongeHTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeH(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeUTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeU(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeVTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: spongeV(0:nx+1, 0:ny+1, layers)
  integer, intent(in) :: nx, ny, layers
  integer, intent(in) :: n
  integer, intent(in) :: debug_level

  ! Bernoulli potential
  double precision :: b(0:nx+1, 0:ny+1, layers)
  ! Relative vorticity
  double precision :: zeta(0:nx+1, 0:ny+1, layers)

  ! Calculate Bernoulli potential
  if (RedGrav) then
    call evaluate_b_RedGrav(b, h, u, v, nx, ny, layers, g_vec)
    if (debug_level .ge. 4) then
      call write_output_3d(b, nx, ny, layers, 0, 0, &
        n, 'output/snap.BP.')
    end if
  else
    call evaluate_b_iso(b, h, u, v, nx, ny, layers, g_vec, depth)
    if (debug_level .ge. 4) then
      call write_output_3d(b, nx, ny, layers, 0, 0, &
        n, 'output/snap.BP.')
    end if
  end if

  ! Calculate relative vorticity
  call evaluate_zeta(zeta, u, v, nx, ny, layers, dx, dy)
  if (debug_level .ge. 4) then
    call write_output_3d(zeta, nx, ny, layers, 1, 1, &
      n, 'output/snap.zeta.')
  end if

  ! Calculate dhdt, dudt, dvdt at current time step
  call evaluate_dhdt(dhdt, h, u, v, kh, kv, dx, dy, nx, ny, layers, &
      spongeHTimeScale, spongeH, wetmask, RedGrav)

  call evaluate_dudt(dudt, h, u, v, b, zeta, wind_x, wind_y, fu, au, ar, slip, &
      dx, dy, hfacN, hfacS, nx, ny, layers, rho0, RelativeWind, Cd, &
      spongeUTimeScale, spongeU, RedGrav, botDrag)

  call evaluate_dvdt(dvdt, h, u, v, b, zeta, wind_x, wind_y, fv, au, ar, slip, &
      dx, dy, hfacW, hfacE, nx, ny, layers, rho0, RelativeWind, Cd, &
      spongeVTimeScale, spongeV, RedGrav, botDrag)

  return
end subroutine state_derivative

! ---------------------------------------------------------------------------
!> Do the isopycnal layer physics

subroutine barotropic_correction(hnew, unew, vnew, eta, etanew, depth, a, &
    dx, dy, wetmask, hfacW, hfacS, dt, &
    maxits, eps, rjac, freesurfFac, thickness_error, &
    debug_level, g_vec, nx, ny, layers, n, &
     MPI_COMM_WORLD, myid, num_procs, ilower, iupper, &
     hypre_grid, hypre_A, ierr)

  implicit none

  double precision, intent(inout) :: hnew(0:nx+1, 0:ny+1, layers)
  double precision, intent(inout) :: unew(0:nx+1, 0:ny+1, layers)
  double precision, intent(inout) :: vnew(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: eta(0:nx+1, 0:ny+1)
  double precision, intent(out)   :: etanew(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: depth(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: a(5, nx, ny)
  double precision, intent(in)    :: dx, dy
  double precision, intent(in)    :: wetmask(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: hfacW(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: hfacS(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: dt
  integer,          intent(in)    :: maxits
  double precision, intent(in)    :: eps, rjac, freesurfFac, thickness_error
  integer,          intent(in)    :: debug_level
  double precision, intent(in)    :: g_vec(layers)
  integer,          intent(in)    :: nx, ny, layers, n
  integer,          intent(in)    :: MPI_COMM_WORLD
  integer,          intent(in)    :: myid, num_procs
  integer,          intent(in)    :: ilower(0:num_procs-1,2)
  integer,          intent(in)    :: iupper(0:num_procs-1,2)
  integer*8,        intent(in)    :: hypre_grid
  integer*8,        intent(in)    :: hypre_A
  integer,          intent(out) :: ierr

  ! barotropic velocity components (for pressure solver)
  double precision :: ub(nx+1, ny)
  double precision :: vb(nx, ny+1)
  double precision :: etastar(0:nx+1, 0:ny+1)

  character(10)    :: num

  ! Calculate the barotropic velocities
  call calc_baro_u(ub, unew, hnew, eta, freesurfFac, nx, ny, layers)
  call calc_baro_v(vb, vnew, hnew, eta, freesurfFac, nx, ny, layers)
  
  if (debug_level .ge. 4) then

    write(num, '(i10.10)') n

    ! Output the data to a file
    open(unit=10, status='replace', file='output/'//'snap.ub.'//num, &
        form='unformatted')
    write(10) ub(1:nx+1, 1:ny)
    close(10)

    open(unit=10, status='replace', file='output/'//'snap.vb.'//num, &
        form='unformatted')
    write(10) vb(1:nx, 1:ny+1)
    close(10)
  end if


  ! Calculate divergence of ub and vb, and solve for the pressure
  ! field that removes it
  call calc_eta_star(ub, vb, eta, etastar, freesurfFac, nx, ny, dx, dy, dt)
  ! print *, maxval(abs(etastar))
  if (debug_level .ge. 4) then
    call write_output_2d(etastar, nx, ny, 0, 0, &
      n, 'output/snap.eta_star.')
  end if

  ! Prevent barotropic signals from bouncing around outside the
  ! wet region of the model.
  ! etastar = etastar*wetmask
#ifndef useExtSolver
  call SOR_solver(a, etanew, etastar, nx, ny, &
     dt, rjac, eps, maxits, n)
  ! print *, maxval(abs(etanew))
#endif

#ifdef useExtSolver
  call Ext_solver(MPI_COMM_WORLD, hypre_A, hypre_grid, myid, num_procs, &
    ilower, iupper, etastar, &
    etanew, nx, ny, dt, maxits, eps, ierr)
#endif

  if (debug_level .ge. 4) then
    call write_output_2d(etanew, nx, ny, 0, 0, &
      n, 'output/snap.eta_new.')
  end if

  etanew = etanew*wetmask

  call wrap_fields_2D(etanew, nx, ny)

  ! Now update the velocities using the barotropic tendency due to
  ! the pressure gradient.
  call update_velocities_for_barotropic_tendency(unew, etanew, g_vec, &
      1, 0, dx, dt, nx, ny, layers)
  call update_velocities_for_barotropic_tendency(vnew, etanew, g_vec, &
      0, 1, dy, dt, nx, ny, layers)

  ! We now have correct velocities at the next time step, but the
  ! layer thicknesses were updated using the velocities without
  ! the barotropic pressure contribution. Force consistency
  ! between layer thicknesses and ocean depth by scaling
  ! thicknesses to agree with free surface.
  call enforce_depth_thickness_consistency(hnew, etanew, depth, &
      freesurfFac, thickness_error, nx, ny, layers)

  ! Apply the boundary conditions
  call apply_boundary_conditions(unew, hfacW, wetmask, nx, ny, layers)
  call apply_boundary_conditions(vnew, hfacS, wetmask, nx, ny, layers)

  return
end subroutine barotropic_correction

! ---------------------------------------------------------------------------
!> Write output if it's time

subroutine maybe_dump_output(h, hav, u, uav, v, vav, eta, etaav, &
        dudt, dvdt, dhdt, &
        dudtold, dvdtold, dhdtold, &
        dudtveryold, dvdtveryold, dhdtveryold, &
        wind_x, wind_y, nx, ny, layers, &
        n, nwrite, avwrite, checkpointwrite, diagwrite, &
        RedGrav, DumpWind, debug_level)
  implicit none

  double precision, intent(in)    :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(inout) :: hav(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(inout) :: uav(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: v(0:nx+1, 0:ny+1, layers)
  double precision, intent(inout) :: vav(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: eta(0:nx+1, 0:ny+1)
  double precision, intent(inout) :: etaav(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: dudt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dvdt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dhdt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dudtold(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dvdtold(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dhdtold(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dudtveryold(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dvdtveryold(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: dhdtveryold(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)    :: wind_x(0:nx+1, 0:ny+1)
  double precision, intent(in)    :: wind_y(0:nx+1, 0:ny+1)
  integer,          intent(in)    :: nx, ny, layers, n
  integer,          intent(in)    :: nwrite, avwrite, checkpointwrite, diagwrite
  logical,          intent(in)    :: RedGrav, DumpWind
  integer,          intent(in)    :: debug_level

  logical       :: dump_output


  ! Write snapshot to file?
  if (mod(n-1, nwrite) .eq. 0) then
    dump_output = .TRUE.
  else if (debug_level .ge. 4) then
    dump_output = .TRUE.
  else
    dump_output = .FALSE.
  end if

  if (dump_output) then 
    
    call write_output_3d(h, nx, ny, layers, 0, 0, &
    n, 'output/snap.h.')
    call write_output_3d(u, nx, ny, layers, 1, 0, &
    n, 'output/snap.u.')
    call write_output_3d(v, nx, ny, layers, 0, 1, &
    n, 'output/snap.v.')


    if (.not. RedGrav) then
      call write_output_2d(eta, nx, ny, 0, 0, &
        n, 'output/snap.eta.')
    end if

    if (DumpWind .eqv. .true.) then
      call write_output_2d(wind_x, nx, ny, 1, 0, &
        n, 'output/wind_x.')
      call write_output_2d(wind_y, nx, ny, 0, 1, &
        n, 'output/wind_y.')
    end if

    if (debug_level .ge. 1) then
      call write_output_3d(dhdt, nx, ny, layers, 0, 0, &
        n, 'output/debug.dhdt.')
      call write_output_3d(dudt, nx, ny, layers, 1, 0, &
        n, 'output/debug.dudt.')
      call write_output_3d(dvdt, nx, ny, layers, 0, 1, &
        n, 'output/debug.dvdt.')
    end if

    ! Check if there are NaNs in the data
    call break_if_NaN(h, nx, ny, layers, n)
    ! call break_if_NaN(u, nx, ny, layers, n)
    ! call break_if_NaN(v, nx, ny, layers, n)

  end if

  ! Write accumulated averages to file?
  if (avwrite .eq. 0) then
    ! OK
  else if (mod(n-1, avwrite) .eq. 0) then

    if (n .eq. 1) then
      ! pass, since dumping averages after first timestep isn't helpful
    else 
      hav = hav/real(avwrite)
      uav = uav/real(avwrite)
      vav = vav/real(avwrite)
      if (.not. RedGrav) then
        etaav = etaav/real(avwrite)
      end if

      call write_output_3d(hav, nx, ny, layers, 0, 0, &
      n, 'output/av.h.')
      call write_output_3d(uav, nx, ny, layers, 1, 0, &
      n, 'output/av.u.')
      call write_output_3d(vav, nx, ny, layers, 0, 1, &
      n, 'output/av.v.')


      if (.not. RedGrav) then
        call write_output_2d(etaav, nx, ny, 0, 0, &
          n, 'output/av.eta.')
      end if

      ! Check if there are NaNs in the data
      call break_if_NaN(h, nx, ny, layers, n)
      ! call break_if_NaN(u, nx, ny, layers, n)
      ! call break_if_NaN(v, nx, ny, layers, n)
    end if
    
    ! Reset average quantities
    hav = 0.0
    uav = 0.0
    vav = 0.0
    if (.not. RedGrav) then
      etaav = 0.0
    end if
    ! h2av = 0.0

  end if

  ! save a checkpoint?
  if (checkpointwrite .eq. 0) then
    ! not saving checkpoints, so move on
  else if (mod(n-1, checkpointwrite) .eq. 0) then
    call write_checkpoint_output(h, nx, ny, layers, &
    n, 'checkpoints/h.')
    call write_checkpoint_output(u, nx, ny, layers, &
    n, 'checkpoints/u.')
    call write_checkpoint_output(v, nx, ny, layers, &
    n, 'checkpoints/v.')

    call write_checkpoint_output(dhdt, nx, ny, layers, &
      n, 'checkpoints/dhdt.')
    call write_checkpoint_output(dudt, nx, ny, layers, &
      n, 'checkpoints/dudt.')
    call write_checkpoint_output(dvdt, nx, ny, layers, &
      n, 'checkpoints/dvdt.')

    call write_checkpoint_output(dhdtold, nx, ny, layers, &
      n, 'checkpoints/dhdtold.')
    call write_checkpoint_output(dudtold, nx, ny, layers, &
      n, 'checkpoints/dudtold.')
    call write_checkpoint_output(dvdtold, nx, ny, layers, &
      n, 'checkpoints/dvdtold.')

    call write_checkpoint_output(dhdtveryold, nx, ny, layers, &
      n, 'checkpoints/dhdtveryold.')
    call write_checkpoint_output(dudtveryold, nx, ny, layers, &
      n, 'checkpoints/dudtveryold.')
    call write_checkpoint_output(dvdtveryold, nx, ny, layers, &
      n, 'checkpoints/dvdtveryold.')

    if (.not. RedGrav) then
      call write_checkpoint_output(eta, nx, ny, 1, &
        n, 'checkpoints/eta.')
    end if

  end if

  if (diagwrite .eq. 0) then
    ! not saving diagnostics. Move one.
  else if (mod(n-1, diagwrite) .eq. 0) then
    call write_diag_output(h, nx, ny, layers, n, 'output/diagnostic.h.csv')
    call write_diag_output(u, nx, ny, layers, n, 'output/diagnostic.u.csv')
    call write_diag_output(v, nx, ny, layers, n, 'output/diagnostic.v.csv')
    if (.not. RedGrav) then
      call write_diag_output(eta, nx, ny, 1, n, 'output/diagnostic.eta.csv')
    end if
  end if

  return
end subroutine maybe_dump_output

! ---------------------------------------------------------------------------

!> Evaluate the Bornoulli Potential for n-layer physics.
!! B is evaluated at the tracer point, for each grid box.
subroutine evaluate_b_iso(b, h, u, v, nx, ny, layers, g_vec, depth)
  implicit none

  ! Evaluate the baroclinic component of the Bernoulli Potential
  ! (u dot u + Montgomery potential) in the n-layer physics, at centre
  ! of grid box

  double precision, intent(out) :: b(0:nx+1, 0:ny+1, layers) !< Bernoulli Potential
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers) !< layer thicknesses
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers) !< zonal velocities
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers) !< meridional velocities
  integer, intent(in) :: nx !< number of x grid points
  integer, intent(in) :: ny !< number of y grid points
  integer, intent(in) :: layers !< number of layers
  double precision, intent(in)  :: g_vec(layers) !< reduced gravity at each interface
  double precision, intent(in)  :: depth(0:nx+1, 0:ny+1) !< total depth of fluid

  integer i, j, k
  double precision z(0:nx+1, 0:ny+1, layers)
  double precision M(0:nx+1, 0:ny+1, layers)

  ! Calculate layer interface locations
  z = 0d0
  z(:, :, layers) = -depth

  do k = 1, layers-1
    z(:, :, layers - k) = z(:, :, layers-k+1) + h(:, :, layers-k+1)
  end do

  ! Calculate Montogmery potential
  ! The following loop is to get the baroclinic Montgomery potential
  ! in each layer
  M = 0d0
  do k = 2, layers
    M(:, :, k) = M(:, :, k-1) + g_vec(k) * z(:, :, k-1)
  end do

  b = 0d0
  ! No baroclinic pressure contribution to the first layer Bernoulli
  ! potential (the barotropic pressure contributes, but that's not
  ! done here).
  ! do j = 1, ny-1
  !     do i = 1, nx-1
  !         b(i,j,1) = (u(i,j,1)**2+u(i+1,j,1)**2+v(i,j,1)**2+v(i,j+1,1)**2)/4.0d0
  !     end do
  ! end do

  ! For the rest of the layers we get a baroclinic pressure contribution
  do k = 1, layers ! move through the different layers of the model
    do j = 1, ny ! move through longitude
      do i = 1, nx ! move through latitude
        b(i,j,k) = M(i,j,k) &
            + (u(i,j,k)**2+u(i+1,j,k)**2+v(i,j,k)**2+v(i,j+1,k)**2)/4.0d0
        ! Add the (u^2 + v^2)/2 term to the Montgomery Potential
      end do
    end do
  end do

  call wrap_fields_3D(b, nx, ny, layers)


  return
end subroutine evaluate_b_iso

! ---------------------------------------------------------------------------

subroutine evaluate_b_RedGrav(b, h, u, v, nx, ny, layers, gr)
  implicit none

  ! Evaluate Bernoulli Potential at centre of grid box
  double precision, intent(out) :: b(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers)
  integer, intent(in) :: nx, ny, layers
  double precision, intent(in)  :: gr(layers)

  integer i, j, k, l, m
  double precision h_temp, b_proto

  b = 0d0

  do k = 1, layers ! move through the different layers of the model
    do j = 1, ny ! move through longitude
      do i = 1, nx ! move through latitude
        ! The following loops are to get the pressure term in the
        ! Bernoulli Potential
        b_proto = 0d0
        do l = k, layers
          h_temp = 0d0
          do m = 1, l
            h_temp = h_temp + h(i, j, m) ! sum up the layer thicknesses
          end do
          ! Sum up the product of reduced gravity and summed layer
          ! thicknesses to form the pressure componenet of the
          ! Bernoulli Potential term
          b_proto = b_proto + gr(l)*h_temp
        end do
        ! Add the (u^2 + v^2)/2 term to the pressure componenet of the
        ! Bernoulli Potential
        b(i,j,k) = b_proto &
            + (u(i,j,k)**2+u(i+1,j,k)**2+v(i,j,k)**2+v(i,j+1,k)**2)/4.0d0
      end do
    end do
  end do

  call wrap_fields_3D(b, nx, ny, layers)

  return
end subroutine evaluate_b_RedGrav

! ---------------------------------------------------------------------------
!> Evaluate relative vorticity at lower left grid boundary (du/dy
!! and dv/dx are at lower left corner as well)
subroutine evaluate_zeta(zeta, u, v, nx, ny, layers, dx, dy)
  implicit none

  double precision, intent(out) :: zeta(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers)
  integer, intent(in) :: nx, ny, layers
  double precision, intent(in)  :: dx, dy

  integer i, j, k

  zeta = 0d0

  do k = 1, layers
    do j = 1, ny+1
      do i = 1, nx+1
        zeta(i,j,k) = (v(i,j,k)-v(i-1,j,k))/dx-(u(i,j,k)-u(i,j-1,k))/dy
      end do
    end do
  end do

  call wrap_fields_3D(zeta, nx, ny, layers)

  return
end subroutine evaluate_zeta

! ---------------------------------------------------------------------------
!> Calculate the tendency of layer thickness for each of the active layers
!! dh/dt is in the centre of each grid point.
subroutine evaluate_dhdt(dhdt, h, u, v, kh, kv, dx, dy, nx, ny, layers, &
    spongeTimeScale, spongeH, wetmask, RedGrav)
  implicit none

  ! dhdt is evaluated at the centre of the grid box
  double precision, intent(out) :: dhdt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: kh(layers), kv
  double precision, intent(in)  :: dx, dy
  integer, intent(in) :: nx, ny, layers
  double precision, intent(in)  :: spongeTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: spongeH(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: wetmask(0:nx+1, 0:ny+1)
  logical, intent(in) :: RedGrav

  integer i, j, k
  ! Thickness tendency due to thickness diffusion (equivalent to Gent
  ! McWilliams in a z coordinate model)
  double precision dhdt_GM(0:nx+1, 0:ny+1, layers)

  ! Thickness tendency due to vertical diffusion of mass
  double precision dhdt_vert_diff(0:nx+1, 0:ny+1, layers)

  ! Calculate tendency due to thickness diffusion (equivalent
  ! to GM in z coordinate model with the same diffusivity).
  dhdt_GM = 0d0
  dhdt_vert_diff = 0d0

  ! Loop through all layers except lowest and calculate
  ! thickness tendency due to horizontal diffusive mass fluxes
  do k = 1, layers-1
    do j = 1, ny
      do i = 1, nx
        dhdt_GM(i,j,k) = &
            kh(k)*(h(i+1,j,k)*wetmask(i+1,j)    &
              + (1d0 - wetmask(i+1,j))*h(i,j,k) & ! reflect around boundary
              + h(i-1,j,k)*wetmask(i-1,j)       &
              + (1d0 - wetmask(i-1,j))*h(i,j,k) & ! refelct around boundary
              - 2*h(i,j,k))/(dx*dx)             & ! x-component

            + kh(k)*(h(i,j+1,k)*wetmask(i,j+1) &
              + (1d0 - wetmask(i,j+1))*h(i,j,k) & ! reflect value around boundary
              + h(i,j-1,k)*wetmask(i,j-1)       &
              + (1d0 - wetmask(i,j-1))*h(i,j,k) & ! reflect value around boundary
              - 2*h(i,j,k))/(dy*dy)               ! y-component horizontal diffusion
      end do
    end do
  end do


  ! Now do the lowest active layer, k = layers. If using reduced
  ! gravity physics, this is unconstrained and calculated as above. If
  ! using n-layer physics it is constrained to balance the layers
  ! above it.
  if (RedGrav) then
    do j = 1, ny
      do i = 1, nx
        dhdt_GM(i,j,layers) = &
            kh(layers)*(h(i+1,j,layers)*wetmask(i+1,j)   &
              + (1d0 - wetmask(i+1,j))*h(i,j,layers)     & ! boundary
              + h(i-1,j,layers)*wetmask(i-1,j)           &
              + (1d0 - wetmask(i-1,j))*h(i,j,layers)     & ! boundary
              - 2*h(i,j,layers))/(dx*dx)                 & ! x-component

            + kh(layers)*(h(i,j+1,layers)*wetmask(i,j+1) &
              + (1d0 - wetmask(i,j+1))*h(i,j,layers)     & ! reflect value around boundary
              + h(i,j-1,layers)*wetmask(i,j-1)           &
              + (1d0 - wetmask(i,j-1))*h(i,j,layers)     & ! reflect value around boundary
              - 2*h(i,j,layers))/(dy*dy) ! y-component horizontal diffusion
      end do
    end do
  else if (.not. RedGrav) then ! using n-layer physics
    ! Calculate bottom layer thickness tendency to balance layers above.
    ! In the flat-bottomed case this will give the same answer.
    dhdt_GM(:,:,layers) = -sum(dhdt_GM(:,:,:layers-1), 3)
  end if

  ! calculate vertical diffusive mass fluxes
  ! only evaluate vertical mass diff flux if more than 1 layer, or reduced gravity
  if (layers .eq. 1) then
    if (RedGrav) then
      do j = 1, ny
        do i = 1, nx
          dhdt_vert_diff(i,j,1) = kv/h(i,j,1)
        end do
      end do
    end if
  else if (layers .gt. 1) then
    ! if more than one layer, need to have multiple fluxes
    do k = 1, layers
      do j = 1, ny
        do i = 1, nx
          if (k .eq. 1) then ! in top layer
            dhdt_vert_diff(i,j,k) = kv/h(i,j,k) - kv/h(i,j,k+1)
          else if (k .eq. layers) then ! bottom layer
            dhdt_vert_diff(i,j,k) = kv/h(i,j,k) - kv/h(i,j,k-1)
          else ! mid layer/s
            dhdt_vert_diff(i,j,k) = 2d0*kv/h(i,j,k) -  &
                kv/h(i,j,k-1) - kv/h(i,j,k+1)
          end if
        end do
      end do
    end do
  end if

  ! Now add this to the thickness tendency due to the flow field and
  ! sponge regions
  dhdt = 0d0

  do k = 1, layers
    do j = 1, ny
      do i = 1, nx
        dhdt(i,j,k) = &
            dhdt_GM(i,j,k) & ! horizontal thickness diffusion
            + dhdt_vert_diff(i,j,k) & ! vetical thickness diffusion 
            - ((h(i,j,k)+h(i+1,j,k))*u(i+1,j,k) &
               - (h(i-1,j,k)+h(i,j,k))*u(i,j,k))/(dx*2d0) & ! d(hu)/dx
            - ((h(i,j,k)+h(i,j+1,k))*v(i,j+1,k) &
              - (h(i,j-1,k)+h(i,j,k))*v(i,j,k))/(dy*2d0)  & ! d(hv)/dy
            + spongeTimeScale(i,j,k)*(spongeH(i,j,k)-h(i,j,k)) ! forced relaxtion in the sponge regions.
      end do
    end do
  end do

  ! Make sure the dynamics are only happening in the wet grid points.
  do k = 1, layers
    dhdt(:, :, k) = dhdt(:, :, k) * wetmask
  end do

  call wrap_fields_3D(dhdt, nx, ny, layers)

  return
end subroutine evaluate_dhdt

! ---------------------------------------------------------------------------
!> Calculate the tendency of zonal velocity for each of the active layers

subroutine evaluate_dudt(dudt, h, u, v, b, zeta, wind_x, wind_y, fu, &
    au, ar, slip, dx, dy, hfacN, hfacS, nx, ny, layers, rho0, & 
    RelativeWind, Cd, spongeTimeScale, spongeU, RedGrav, botDrag)
  implicit none

  ! dudt(i, j) is evaluated at the centre of the left edge of the grid
  ! box, the same place as u(i, j).
  double precision, intent(out) :: dudt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: b(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: zeta(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: wind_x(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: wind_y(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: fu(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: au, ar, slip, dx, dy
  double precision, intent(in)  :: hfacN(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: hfacS(0:nx+1, 0:ny+1)
  integer, intent(in) :: nx, ny, layers
  double precision, intent(in)  :: rho0
  logical,          intent(in)  :: RelativeWind
  double precision, intent(in)  :: Cd
  double precision, intent(in)  :: spongeTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: spongeU(0:nx+1, 0:ny+1, layers)
  logical, intent(in) :: RedGrav
  double precision, intent(in)  :: botDrag

  integer i, j, k

  dudt = 0d0

  do k = 1, layers
    do j = 1, ny
      do i = 1, nx
        dudt(i,j,k) = au*(u(i+1,j,k)+u(i-1,j,k)-2.0d0*u(i,j,k))/(dx*dx) & ! x-component
            + au*(u(i,j+1,k)+u(i,j-1,k)-2.0d0*u(i,j,k) &
              ! boundary conditions
              + (1.0d0 - 2.0d0*slip)*(1.0d0 - hfacN(i,j))*u(i,j,k) &
              + (1.0d0 - 2.0d0*slip)*(1.0d0 - hfacS(i,j))*u(i,j,k))/(dy*dy) & ! y-component
              ! Together make the horizontal diffusion term
            + 0.25d0*(fu(i,j)+0.5d0*(zeta(i,j,k)+zeta(i,j+1,k))) &
              *(v(i-1,j,k)+v(i,j,k)+v(i-1,j+1,k)+v(i,j+1,k)) & ! vorticity term
            - (b(i,j,k) - b(i-1,j,k))/dx & ! Bernoulli potential term
            + spongeTimeScale(i,j,k)*(spongeU(i,j,k)-u(i,j,k)) ! forced relaxtion in the sponge regions
        if (k .eq. 1) then ! only have wind forcing on the top layer
          ! This will need refining in the event of allowing outcropping.
          ! apply wind forcing
          if (RelativeWind) then 
            dudt(i,j,k) = dudt(i,j,k) + (2d0*Cd* & 
                 (wind_x(i,j) - u(i,j,k))* & 
              sqrt((wind_x(i,j) - u(i,j,k))**2 + &
                   (wind_y(i,j) - v(i,j,k))**2))/((h(i,j,k) + h(i-1,j,k)))
          else 
            dudt(i,j,k) = dudt(i,j,k) + 2d0*wind_x(i,j)/(rho0*(h(i,j,k) + h(i-1,j,k))) 
          end if
        end if
        if (layers .gt. 1) then ! only evaluate vertical momentum diffusivity if more than 1 layer
          if (k .eq. 1) then ! adapt vertical momentum diffusivity for 2+ layer model -> top layer
            dudt(i,j,k) = dudt(i,j,k) - 1.0d0*ar*(u(i,j,k) - 1.0d0*u(i,j,k+1))
          else if (k .eq. layers) then ! bottom layer
            dudt(i,j,k) = dudt(i,j,k) - 1.0d0*ar*(u(i,j,k) - 1.0d0*u(i,j,k-1))
            if (.not. RedGrav) then
              ! add bottom drag here in isopycnal version
              dudt(i,j,k) = dudt(i,j,k) - 1.0d0*botDrag*(u(i,j,k))
            end if
          else ! mid layer/s
            dudt(i,j,k) = dudt(i,j,k) - &
                1.0d0*ar*(2.0d0*u(i,j,k) - 1.0d0*u(i,j,k-1) - 1.0d0*u(i,j,k+1))
          end if
        end if
      end do
    end do
  end do

  call wrap_fields_3D(dudt, nx, ny, layers)

  return
end subroutine evaluate_dudt

! ---------------------------------------------------------------------------
!> Calculate the tendency of meridional velocity for each of the
!> active layers

subroutine evaluate_dvdt(dvdt, h, u, v, b, zeta, wind_x, wind_y, fv, &
    au, ar, slip, dx, dy, hfacW, hfacE, nx, ny, layers, rho0, &
    RelativeWind, Cd, spongeTimeScale, spongeV, RedGrav, botDrag)
  implicit none

  ! dvdt(i, j) is evaluated at the centre of the bottom edge of the
  ! grid box, the same place as v(i, j)
  double precision, intent(out) :: dvdt(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: b(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: zeta(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: wind_x(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: wind_y(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: fv(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: au, ar, slip
  double precision, intent(in)  :: dx, dy
  double precision, intent(in)  :: hfacW(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: hfacE(0:nx+1, 0:ny+1)
  integer, intent(in) :: nx, ny, layers
  double precision, intent(in)  :: rho0
  logical,          intent(in)  :: RelativeWind
  double precision, intent(in)  :: Cd
  double precision, intent(in)  :: spongeTimeScale(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: spongeV(0:nx+1, 0:ny+1, layers)
  logical, intent(in) :: RedGrav
  double precision, intent(in)  :: botDrag

  integer i, j, k

  dvdt = 0d0

  do k = 1, layers
    do j = 1, ny
      do i = 1, nx
        dvdt(i,j,k) = &
            au*(v(i+1,j,k)+v(i-1,j,k)-2.0d0*v(i,j,k) &
              ! boundary conditions
              + (1.0d0 - 2.0d0*slip)*(1.0d0 - hfacW(i,j))*v(i,j,k) &
              + (1.0d0 - 2.0d0*slip)*(1.0d0 - hfacE(i,j))*v(i,j,k))/(dx*dx) & !x-component
            + au*(v(i,j+1,k) + v(i,j-1,k) - 2.0d0*v(i,j,k))/(dy*dy) & ! y-component.
            ! Together these make the horizontal diffusion term
            - 0.25d0*(fv(i,j)+0.5d0*(zeta(i,j,k)+zeta(i+1,j,k))) &
              *(u(i,j-1,k)+u(i,j,k)+u(i+1,j-1,k)+u(i+1,j,k)) & !vorticity term
            - (b(i,j,k)-b(i,j-1,k))/dy & ! Bernoulli Potential term
            + spongeTimeScale(i,j,k)*(spongeV(i,j,k)-v(i,j,k)) ! forced relaxtion to vsponge (in the sponge regions)
        if (k .eq. 1) then ! only have wind forcing on the top layer
          ! This will need refining in the event of allowing outcropping.
          ! apply wind forcing
          if (RelativeWind) then 
            dvdt(i,j,k) = dvdt(i,j,k) + (2d0*Cd* & 
                 (wind_y(i,j) - v(i,j,k))* & 
              sqrt((wind_x(i,j) - u(i,j,k))**2 + &
                   (wind_y(i,j) - v(i,j,k))**2))/((h(i,j,k) + h(i,j-1,k)))
          else 
            dvdt(i,j,k) = dvdt(i,j,k) + 2d0*wind_y(i,j)/(rho0*(h(i,j,k) + h(i,j-1,k))) 
          end if
        end if
        if (layers .gt. 1) then ! only evaluate vertical momentum diffusivity if more than 1 layer
          if (k .eq. 1) then ! adapt vertical momentum diffusivity for 2+ layer model -> top layer
            dvdt(i,j,k) = dvdt(i,j,k) - 1.0d0*ar*(v(i,j,k) - 1.0d0*v(i,j,k+1))
          else if (k .eq. layers) then ! bottom layer
            dvdt(i,j,k) = dvdt(i,j,k) - 1.0d0*ar*(v(i,j,k) - 1.0d0*v(i,j,k-1))
            if (.not. RedGrav) then
              ! add bottom drag here in isopycnal version
              dvdt(i,j,k) = dvdt(i,j,k) - 1.0d0*botDrag*(v(i,j,k))
            end if
          else ! mid layer/s
            dvdt(i,j,k) = dvdt(i,j,k) - &
                1.0d0*ar*(2.0d0*v(i,j,k) - 1.0d0*v(i,j,k-1) - 1.0d0*v(i,j,k+1))
          end if
        end if
      end do
    end do
  end do

  call wrap_fields_3D(dvdt, nx, ny, layers)

  return
end subroutine evaluate_dvdt

! ---------------------------------------------------------------------------
!> Calculate the barotropic u velocity

subroutine calc_baro_u(ub, u, h, eta, freesurfFac, nx, ny, layers)
  implicit none

  double precision, intent(out) :: ub(nx+1, ny)
  double precision, intent(in)  :: u(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: eta(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: freesurfFac
  integer, intent(in) :: nx, ny, layers

  integer i, j, k
  double precision h_temp(0:nx+1, 0:ny+1, layers)

  ub = 0d0

  h_temp = h
  ! add free surface elevation to the upper layer
  h_temp(:, :, 1) = h(:, :, 1) + eta*freesurfFac

  do i = 1, nx+1
    do j = 1, ny
      do k = 1, layers
        ub(i,j) = ub(i,j) + u(i,j,k)*(h_temp(i,j,k)+h_temp(i-1,j,k))/2d0
      end do
    end do
  end do

  return
end subroutine calc_baro_u

! ---------------------------------------------------------------------------
!> Calculate the barotropic v velocity

subroutine calc_baro_v(vb, v, h, eta, freesurfFac, nx, ny, layers)
  implicit none

  double precision, intent(out) :: vb(nx, ny+1)
  double precision, intent(in)  :: v(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in)  :: eta(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: freesurfFac
  integer, intent(in) :: nx, ny, layers

  integer i, j, k
  double precision h_temp(0:nx+1, 0:ny+1, layers)

  vb = 0d0

  h_temp = h
  ! add free surface elevation to the upper layer
  h_temp(:, :, 1) = h(:, :, 1) + eta*freesurfFac

  do i = 1, nx
    do j = 1, ny+1
      do k = 1, layers
        vb(i,j) = vb(i,j) + v(i,j,k)*(h_temp(i,j,k)+h_temp(i,j-1,k))/2d0
      end do
    end do
  end do

  return
end subroutine calc_baro_v

! ---------------------------------------------------------------------------
!> Calculate the free surface anomaly using the velocities
!! timestepped with the tendencies excluding the free surface
!! pressure gradient.

subroutine calc_eta_star(ub, vb, eta, etastar, &
    freesurfFac, nx, ny, dx, dy, dt)
  implicit none

  double precision, intent(in)  :: ub(nx+1, ny)
  double precision, intent(in)  :: vb(nx, ny+1)
  double precision, intent(in)  :: eta(0:nx+1, 0:ny+1)
  double precision, intent(out) :: etastar(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: freesurfFac
  integer, intent(in) :: nx, ny
  double precision, intent(in) :: dx, dy, dt

  integer i, j

  etastar = 0d0

  do i = 1, nx
    do j = 1, ny
      etastar(i,j) = freesurfFac*eta(i,j) - &
          dt*((ub(i+1,j) - ub(i,j))/dx + (vb(i,j+1) - vb(i,j))/dy)
    end do
  end do

  call wrap_fields_2D(etastar, nx, ny)

  return
end subroutine calc_eta_star

! ---------------------------------------------------------------------------
!> Use the successive over-relaxation algorithm to solve the backwards
!! Euler timestepping for the free surface anomaly, or for the surface
!! pressure required to keep the barotropic flow nondivergent.

subroutine SOR_solver(a, etanew, etastar, nx, ny, dt, &
    rjac, eps, maxits, n)
  implicit none

  double precision, intent(in)  :: a(5, nx, ny)
  double precision, intent(out) :: etanew(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: etastar(0:nx+1, 0:ny+1)
  integer, intent(in) :: nx, ny
  double precision, intent(in) :: dt
  double precision, intent(in) :: rjac, eps
  integer, intent(in) :: maxits, n

  integer i, j, nit
  double precision rhs(nx, ny)
  double precision res(nx, ny)
  double precision norm, norm0
  double precision relax_param

  rhs = -etastar(1:nx,1:ny)/dt**2
  ! first guess for etanew
  etanew = etastar

  relax_param = 1.d0 ! successive over-relaxation parameter

  ! Calculate initial residual, so that we can stop the loop when the
  ! current residual = norm0*eps
  norm0 = 0.d0
  do i = 1, nx
    do j = 1, ny
      res(i,j) = &
          a(1,i,j)*etanew(i+1,j) &
          + a(2,i,j)*etanew(i,j+1) &
          + a(3,i,j)*etanew(i-1,j) &
          + a(4,i,j)*etanew(i,j-1) &
          + a(5,i,j)*etanew(i,j)   &
          - rhs(i,j)
      norm0 = norm0 + abs(res(i,j))
      etanew(i,j) = etanew(i,j)-relax_param*res(i,j)/a(5,i,j)
    end do
  end do


  do nit = 1, maxits
    norm = 0.d0
    do i = 1, nx
      do j = 1, ny
        res(i,j) = &
            a(1,i,j)*etanew(i+1,j) &
            + a(2,i,j)*etanew(i,j+1) &
            + a(3,i,j)*etanew(i-1,j) &
            + a(4,i,j)*etanew(i,j-1) &
            + a(5,i,j)*etanew(i,j)   &
            - rhs(i,j)
        norm = norm + abs(res(i,j))
        etanew(i,j) = etanew(i,j)-relax_param*res(i,j)/(a(5,i,j))
      end do
    end do
    if (nit.eq.1) then
      relax_param = 1.d0/(1.d0-0.5d0*rjac**2)
    else
      relax_param = 1.d0/(1.d0-0.25d0*rjac**2*relax_param)
    end if

    call wrap_fields_2D(etanew, nx, ny)

    if (nit.gt.1.and.norm.lt.eps*norm0) then

      return

    end if
  end do

  write(17, "(A, I0)") 'Warning: maximum SOR iterations exceeded at time step ', n

  return
end subroutine SOR_solver

! ---------------------------------------------------------------------------

subroutine create_Hypre_grid(MPI_COMM_WORLD, hypre_grid, ilower, iupper, &
          num_procs, myid, nx, ny, ierr)
  implicit none

  integer,   intent(in)  :: MPI_COMM_WORLD
  integer*8, intent(out) :: hypre_grid
  integer,   intent(in)  :: ilower(0:num_procs-1,2)
  integer,   intent(in)  :: iupper(0:num_procs-1,2)
  integer,   intent(in)  :: num_procs
  integer,   intent(in)  :: myid
  integer,   intent(in)  :: nx
  integer,   intent(in)  :: ny
  integer,   intent(out)  :: ierr

#ifdef useExtSolver
  call Hypre_StructGridCreate(MPI_COMM_WORLD, 2, hypre_grid, ierr)

  !do i = 0, num_procs-1
  call HYPRE_StructGridSetExtents(hypre_grid, ilower(myid,:),iupper(myid,:), ierr)
  !end do

  call HYPRE_StructGridSetPeriodic(hypre_grid, [nx, ny], ierr)

  call HYPRE_StructGridAssemble(hypre_grid, ierr)
#endif

  return
end subroutine create_Hypre_grid

! ---------------------------------------------------------------------------

subroutine create_Hypre_A_matrix(MPI_COMM_WORLD, hypre_grid, hypre_A, &
          a, nx, ny, ierr)
  implicit none

  integer,          intent(in)  :: MPI_COMM_WORLD
  integer*8,        intent(in)  :: hypre_grid
  integer*8,        intent(out) :: hypre_A
  double precision, intent(in)  :: a(5, nx, ny)
  integer,          intent(in)  :: nx, ny
  integer,          intent(out) :: ierr

  ! Hypre stencil for creating the A matrix
  integer*8 :: stencil

  integer :: offsets(2,5)
  integer :: indicies(2)
  integer :: i, j

#ifdef useExtSolver

  ! Define the geometry of the stencil.  Each represents a relative
  ! offset (in the index space).
  offsets(1,1) =  0
  offsets(2,1) =  0
  offsets(1,2) = -1
  offsets(2,2) =  0
  offsets(1,3) =  1
  offsets(2,3) =  0
  offsets(1,4) =  0
  offsets(2,4) = -1
  offsets(1,5) =  0
  offsets(2,5) =  1


  call HYPRE_StructStencilCreate(2, 5, stencil, ierr)
  ! this gives a 2D, 5 point stencil centred around the grid point of interest.
  do i = 0, 4
    call HYPRE_StructStencilSetElement(stencil, i, offsets(:,i+1),ierr)
  end do

  call HYPRE_StructMatrixCreate(MPI_COMM_WORLD, hypre_grid, stencil, hypre_A, ierr)

  call HYPRE_StructMatrixInitialize(hypre_A, ierr)

  do i = 1, nx
    do j = 1, ny
      indicies(1) = i
      indicies(2) = j

      call HYPRE_StructMatrixSetValues(hypre_A, &
          indicies, 1, 0, &
          a(5,i,j), ierr)
      call HYPRE_StructMatrixSetValues(hypre_A, &
          indicies, 1, 1, &
          a(3,i,j), ierr)
      call HYPRE_StructMatrixSetValues(hypre_A, &
          indicies, 1, 2, &
          a(1,i,j), ierr)
      call HYPRE_StructMatrixSetValues(hypre_A, &
          indicies, 1, 3, &
          a(4,i,j), ierr)
      call HYPRE_StructMatrixSetValues(hypre_A, &
          indicies, 1, 4, &
          a(2,i,j), ierr)
    end do
  end do

  call HYPRE_StructMatrixAssemble(hypre_A, ierr)

  call MPI_Barrier(MPI_COMM_WORLD, ierr)

#endif

  return
end subroutine create_Hypre_A_matrix

! ---------------------------------------------------------------------------

subroutine Ext_solver(MPI_COMM_WORLD, hypre_A, hypre_grid, myid, num_procs, &
    ilower, iupper, etastar, &
    etanew, nx, ny, dt, maxits, eps, ierr)
  implicit none

  integer,          intent(in)  :: MPI_COMM_WORLD
  integer*8,        intent(in)  :: hypre_A
  integer*8,        intent(in)  :: hypre_grid
  integer,          intent(in)  :: myid
  integer,          intent(in)  :: num_procs
  integer,          intent(in)  :: ilower(0:num_procs-1,2)
  integer,          intent(in)  :: iupper(0:num_procs-1,2)
  double precision, intent(in)  :: etastar(0:nx+1, 0:ny+1)
  double precision, intent(out) :: etanew(0:nx+1, 0:ny+1)
  integer,          intent(in)  :: nx, ny
  double precision, intent(in)  :: dt
  integer,          intent(in)  :: maxits
  double precision, intent(in)  :: eps
  integer,          intent(out) :: ierr

  integer          :: i, j ! loop variables
  integer*8        :: hypre_b
  integer*8        :: hypre_x
  integer*8        :: hypre_solver
  integer*8        :: precond
  double precision, dimension(:),     allocatable :: values

  integer :: nx_tile, ny_tile

  nx_tile = iupper(myid,1)-ilower(myid,1) + 1
  ny_tile = iupper(myid,2)-ilower(myid,2) + 1

  allocate(values(nx_tile*ny_tile))
  ! just nx*ny for the tile this processor owns


  ! A currently unused variable that can be used to
  ! print information from the solver - see comments below.
!  double precision :: hypre_out(2)


  ! wrap this code in preprocessing flags to allow the model to be compiled without the external library, if desired.
#ifdef useExtSolver
  ! Create the rhs vector, b
  call HYPRE_StructVectorCreate(MPI_COMM_WORLD, hypre_grid, hypre_b, ierr)
  call HYPRE_StructVectorInitialize(hypre_b, ierr)

  ! set rhs values (vector b)
  do j = ilower(myid,2), iupper(myid,2) ! loop over every grid point
    do i = ilower(myid,1), iupper(myid,1)
  ! the 2D array is being laid out like
  ! [x1y1, x2y1, x3y1, x1y2, x2y2, x3y2, x1y3, x2y3, x3y3]
    values( ((j-1)*nx_tile + i) ) = -etastar(i,j)/dt**2
    end do
  end do

  call HYPRE_StructVectorSetBoxValues(hypre_b, &
    ilower(myid,:), iupper(myid,:), values, ierr)

  call HYPRE_StructVectorAssemble(hypre_b, ierr)

  ! now create the x vector
  call HYPRE_StructVectorCreate(MPI_COMM_WORLD, hypre_grid, hypre_x, ierr)
  call HYPRE_StructVectorInitialize(hypre_x, ierr)

  call HYPRE_StructVectorSetBoxValues(hypre_x, &
    ilower(myid,:), iupper(myid,:), values, ierr)

  call HYPRE_StructVectorAssemble(hypre_x, ierr)

  ! now create the solver and solve the equation.
  ! Choose the solver
  call HYPRE_StructPCGCreate(MPI_COMM_WORLD, hypre_solver, ierr)

  ! Set some parameters
  call HYPRE_StructPCGSetMaxIter(hypre_solver, maxits, ierr)
  call HYPRE_StructPCGSetTol(hypre_solver, eps, ierr)
  ! other options not explained by user manual but present in examples
  ! call HYPRE_StructPCGSetMaxIter(hypre_solver, 50 );
  ! call HYPRE_StructPCGSetTol(hypre_solver, 1.0e-06 );
  call HYPRE_StructPCGSetTwoNorm(hypre_solver, 1 );
  call HYPRE_StructPCGSetRelChange(hypre_solver, 0 );
  call HYPRE_StructPCGSetPrintLevel(hypre_solver, 1 ); ! 2 will print each CG iteration
  call HYPRE_StructPCGSetLogging(hypre_solver, 1);

  ! use an algebraic multigrid preconditioner
  call HYPRE_BoomerAMGCreate(precond, ierr)
  ! values taken from hypre library example number 5
  ! print less solver info since a preconditioner
  call HYPRE_BoomerAMGSetPrintLevel(precond, 1, ierr);
  ! Falgout coarsening
  call HYPRE_BoomerAMGSetCoarsenType(precond, 6, ierr)
  ! old defaults
  call HYPRE_BoomerAMGSetOldDefault(precond, ierr)
  ! SYMMETRIC G-S/Jacobi hybrid relaxation
  call HYPRE_BoomerAMGSetRelaxType(precond, 6, ierr)
  ! Sweeeps on each level
  call HYPRE_BoomerAMGSetNumSweeps(precond, 1, ierr)
  ! conv. tolerance
  call HYPRE_BoomerAMGSetTol(precond, 0.0d0, ierr)
  ! do only one iteration!
  call HYPRE_BoomerAMGSetMaxIter(precond, 1, ierr)

  ! set amg as the pcg preconditioner
  call HYPRE_StructPCGSetPrecond(hypre_solver, 2, precond, ierr)


  ! now we set the system up and do the actual solve!
  call HYPRE_StructPCGSetup(hypre_solver, hypre_A, hypre_b, &
                            hypre_x, ierr)

  call HYPRE_ParCSRPCGSolve(hypre_solver, hypre_A, hypre_b, &
                            hypre_x, ierr)

  ! code for printing out results from the external solver
  ! Not being used, but left here since the manual isn't very helpful
  ! and this may be useful in the future.
  ! call HYPRE_ParCSRPCGGetNumIterations(hypre_solver, &
  !   hypre_out(1), ierr)
  ! print *, 'num iterations = ', hypre_out(1)

  ! call HYPRE_ParCSRPCGGetFinalRelative(hypre_solver, &
  !   hypre_out(2), ierr)
  ! print *, 'final residual norm = ', hypre_out(2)

  call HYPRE_StructVectorGetBoxValues(hypre_x, &
    ilower(myid,:), iupper(myid,:), values, ierr)

  do j = ilower(myid,2), iupper(myid,2) ! loop over every grid point
    do i = ilower(myid,1), iupper(myid,1)
    etanew(i,j) = values( ((j-1)*nx_tile + i) )
    end do
  end do

  ! debugging commands from hypre library - dump out a single
  ! copy of these two variables. Can be used to check that the
  ! values have been properly allocated.
  ! call HYPRE_StructVectorPrint(hypre_x, ierr)
  ! call HYPRE_StructMatrixPrint(hypre_A, ierr)

  call HYPRE_StructPCGDestroy(hypre_solver, ierr)
  call HYPRE_BoomerAMGDestroy(precond, ierr)
  call HYPRE_StructVectorDestroy(hypre_x, ierr)
  call HYPRE_StructVectorDestroy(hypre_b, ierr)

#endif

  return
end subroutine Ext_solver

! ---------------------------------------------------------------------------

!> Update velocities using the barotropic tendency due to the pressure
!> gradient.

subroutine update_velocities_for_barotropic_tendency(array, etanew, g_vec, &
    xstep, ystep, dspace, dt, nx, ny, layers)
  implicit none

  double precision, intent(inout) :: array(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: etanew(0:nx+1, 0:ny+1)
  double precision, intent(in) :: g_vec(layers)
  integer, intent(in) :: xstep, ystep
  double precision, intent(in) :: dspace, dt
  integer, intent(in) :: nx, ny, layers

  integer i, j, k
  double precision baro_contrib

  ! TODO Assert that xstep and ystep are either 1, 0 or 0, 1.

  do i = xstep, nx
    do j = ystep, ny
      do k = 1, layers
        baro_contrib = &
            -g_vec(1)*(etanew(i,j) - etanew(i-xstep,j-ystep))/(dspace)
        array(i,j,k) = array(i,j,k) + dt*baro_contrib
      end do
    end do
  end do


  return
end subroutine update_velocities_for_barotropic_tendency

! ---------------------------------------------------------------------------
!> Check that the free surface anomaly and layer thicknesses are consistent with the depth field. If they're not, then scale the layer thicnkesses to make them fit.

subroutine enforce_depth_thickness_consistency(h, eta, depth, &
    freesurfFac, thickness_error, nx, ny, layers)
  implicit none

  double precision, intent(inout) :: h(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: eta(0:nx+1, 0:ny+1)
  double precision, intent(in) :: depth(0:nx+1, 0:ny+1)
  double precision, intent(in) :: freesurfFac, thickness_error
  integer, intent(in) :: nx, ny, layers

  integer k
  double precision h_norming(0:nx+1, 0:ny+1)

  h_norming = (freesurfFac*eta + depth) / sum(h,3)
  do k = 1, layers
    h(:, :, k) = h(:, :, k) * h_norming
  end do

  if (maxval(abs(h_norming - 1d0)) .gt. thickness_error) then
    write(17, "(A, F6.3, A)") 'Inconsistency between h and eta: ', &
        maxval(abs(h_norming - 1d0))*100d0, '%'
  end if

  return
end subroutine enforce_depth_thickness_consistency

! ---------------------------------------------------------------------------
!> Ensure that layer heights do not fall below the prescribed minimum

subroutine enforce_minimum_layer_thickness(hnew, hmin, nx, ny, layers, n)
  implicit none

  double precision, intent(inout) :: hnew(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: hmin
  integer, intent(in) :: nx, ny, layers, n

  integer counter, i, j, k

  counter = 0

  do k = 1, layers
    do j = 1, ny
      do i = 1, nx
        if (hnew(i, j, k) .lt. hmin) then
          hnew(i, j, k) = hmin
          counter = counter + 1
          if (counter .eq. 1) then
            write(17, "(A, I0)") &
                "Layer thickness dropped below hmin at time step ", n
          end if
        end if
      end do
    end do
  end do
  return
end subroutine enforce_minimum_layer_thickness

! ---------------------------------------------------------------------------
!> Check to see if there are any NaNs in the data field and stop the
!! calculation if any are found.

subroutine break_if_NaN(data, nx, ny, layers, n)
  implicit none

  ! To stop the program if it detects a NaN in the variable being checked

  integer, intent(in) :: nx, ny, layers, n
  double precision, intent(in) :: data(0:nx+1, 0:ny+1, layers)

  integer :: i, j, k

  do k = 1, layers
    do j = 1, ny
      do i = 1, nx
        if (data(i,j,k) .ne. data(i,j,k)) then
          write(17, "(A, I0)") "NaN detected at time step ", n
          call clean_stop(n, .FALSE.)
        end if
      end do
    end do
  end do

  return
end subroutine break_if_NaN

!----------------------------------------------------------------------------
!> Define masks for boundary conditions in u and v.
!! This finds locations where neighbouring grid boxes are not the same
!! (i.e. one is land and one is ocean).
!! In the output,
!! 0 means barrier
!! 1 mean open

subroutine calc_boundary_masks(wetmask, hfacW, hfacE, hfacS, hfacN, nx, ny)
  implicit none

  double precision, intent(in)  :: wetmask(0:nx+1, 0:ny+1)
  double precision, intent(out) :: hfacW(0:nx+1, 0:ny+1)
  double precision, intent(out) :: hfacE(0:nx+1, 0:ny+1)
  double precision, intent(out) :: hfacN(0:nx+1, 0:ny+1)
  double precision, intent(out) :: hfacS(0:nx+1, 0:ny+1)
  integer, intent(in) :: nx !< number of grid points in x direction
  integer, intent(in) :: ny !< number of grid points in y direction

  double precision temp(0:nx+1, 0:ny+1)
  integer i, j

  hfacW = 1d0

  temp = 0.0
  do j = 0, ny+1
    do i = 1, nx+1
      temp(i, j) = wetmask(i-1, j) - wetmask(i, j)
    end do
  end do

  do j = 0, ny+1
    do i = 1, nx+1
      if (temp(i, j) .ne. 0.0) then
        hfacW(i, j) = 0d0
      end if
    end do
  end do

  ! and now for all  western cells
  hfacW(0, :) = hfacW(nx, :)

  hfacE = 1d0

  temp = 0.0
  do j = 0, ny+1
    do i = 0, nx
      temp(i, j) = wetmask(i, j) - wetmask(i+1, j)
    end do
  end do

  do j = 0, ny+1
    do i = 0, nx
      if (temp(i, j) .ne. 0.0) then
        hfacE(i, j) = 0d0
      end if
    end do
  end do

  ! and now for all  eastern cells
  hfacE(nx+1, :) = hfacE(1, :)

  hfacS = 1

  temp = 0.0
  do j = 1, ny+1
    do i = 0, nx+1
      temp(i, j) = wetmask(i, j-1) - wetmask(i, j)
    end do
  end do

  do j = 1, ny+1
    do i = 0, nx+1
      if (temp(i, j) .ne. 0.0) then
        hfacS(i, j) = 0d0
      end if
    end do
  end do

  ! all southern cells
  hfacS(:, 0) = hfacS(:, ny)

  hfacN = 1
  temp = 0.0
  do j = 0, ny
    do i = 0, nx+1
      temp(i, j) = wetmask(i, j) - wetmask(i, j+1)
    end do
  end do

  do j = 0, ny
    do i = 0, nx+1
      if (temp(i, j) .ne. 0.0) then
        hfacN(i, j) = 0d0
      end if
    end do
  end do
  ! all northern cells
  hfacN(:, ny+1) = hfacN(:, 1)

  return
end subroutine calc_boundary_masks

! ---------------------------------------------------------------------------
!> Apply the boundary conditions

subroutine apply_boundary_conditions(array, hfac, wetmask, nx, ny, layers)
  implicit none

  double precision, intent(inout) :: array(0:nx+1,0:ny+1,layers)
  double precision, intent(in) :: hfac(0:nx+1,0:ny+1)
  double precision, intent(in) :: wetmask(0:nx+1,0:ny+1)
  integer, intent(in) :: nx, ny, layers

  integer k

  ! - Enforce no normal flow boundary condition
  !   and no flow in dry cells.
  ! - no/free-slip is done inside the dudt and dvdt subroutines.
  ! - hfacW and hfacS are zero where the transition between
  !   wet and dry cells occurs.
  ! - wetmask is 1 in wet cells, and zero in dry cells.

  do k = 1, layers
    array(:, :, k) = array(:, :, k) * hfac * wetmask(:, :)
  end do

  return
end subroutine apply_boundary_conditions

! ---------------------------------------------------------------------------
!> Compute derivatives of the depth field for the pressure solver

subroutine calc_A_matrix(a, depth, g, dx, dy, nx, ny, freesurfFac, dt, &
          hfacW, hfacE, hfacS, hfacN)
  implicit none

  double precision, intent(out) :: a(5, nx, ny)
  double precision, intent(in)  :: depth(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: g, dx, dy
  integer, intent(in)           :: nx, ny
  double precision, intent(in)  :: freesurfFac
  double precision, intent(in)  :: dt
  double precision, intent(in)  :: hfacW(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: hfacE(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: hfacN(0:nx+1, 0:ny+1)
  double precision, intent(in)  :: hfacS(0:nx+1, 0:ny+1)

  integer i, j

  do j = 1, ny
    do i = 1, nx
      a(1,i,j) = g*0.5*(depth(i+1,j)+depth(i,j))*hfacE(i,j)/dx**2
      a(2,i,j) = g*0.5*(depth(i,j+1)+depth(i,j))*hfacN(i,j)/dy**2
      a(3,i,j) = g*0.5*(depth(i,j)+depth(i-1,j))*hfacW(i,j)/dx**2
      a(4,i,j) = g*0.5*(depth(i,j)+depth(i,j-1))*hfacS(i,j)/dy**2
    end do
  end do

  do j = 1, ny
    do i = 1, nx
      a(5,i,j) = -a(1,i,j)-a(2,i,j)-a(3,i,j)-a(4,i,j) - freesurfFac/dt**2
    end do
  end do

  return
end subroutine calc_A_matrix

! ---------------------------------------------------------------------------

subroutine read_input_fileH(name, array, default, nx, ny, layers)
  implicit none

  character(60), intent(in) :: name
  double precision, intent(out) :: array(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: default(layers)
  integer, intent(in) :: nx, ny, layers

  double precision array_small(nx, ny, layers)
  integer k



  if (name.ne.'') then
    open(unit=10, form='unformatted', file=name)
    read(10) array_small
    close(10)
    array(1:nx, 1:ny, :) = array_small
    call wrap_fields_3D(array, nx, ny, layers)
  else
    do k = 1, layers
      array(:, :, k) = default(k)
    end do
  end if

  return
end subroutine read_input_fileH

! ---------------------------------------------------------------------------

subroutine read_input_fileH_2D(name, array, default, nx, ny)
  implicit none

  character(60), intent(in) :: name
  double precision, intent(out) :: array(0:nx+1, 0:ny+1)
  double precision, intent(in) :: default
  integer, intent(in) :: nx, ny

  double precision array_small(nx, ny)

  if (name.ne.'') then
    open(unit=10, form='unformatted', file=name)
    read(10) array_small
    close(10)
    array(1:nx, 1:ny) = array_small
    call wrap_fields_2D(array, nx, ny)
  else
    array = default
  end if

  return
end subroutine read_input_fileH_2D

! ---------------------------------------------------------------------------

subroutine read_input_fileU(name, array, default, nx, ny, layers)
  implicit none

  character(60), intent(in) :: name
  double precision, intent(out) :: array(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: default
  integer, intent(in) :: nx, ny, layers

  double precision array_small(nx+1, ny, layers)

  if (name.ne.'') then
    open(unit=10, form='unformatted', file=name)
    read(10) array_small
    close(10)
    array(1:nx+1, 1:ny, :) = array_small
    call wrap_fields_3D(array, nx, ny, layers)
  else
    array = default
  end if

  return
end subroutine read_input_fileU

! ---------------------------------------------------------------------------

subroutine read_input_fileV(name, array, default, nx, ny, layers)
  implicit none

  character(60), intent(in) :: name
  double precision, intent(out) :: array(0:nx+1, 0:ny+1, layers)
  double precision, intent(in) :: default
  integer, intent(in) :: nx, ny, layers

  double precision array_small(nx, ny+1, layers)

  if (name.ne.'') then
    open(unit=10, form='unformatted', file=name)
    read(10) array_small
    close(10)
    array(1:nx, 1:ny+1, :) = array_small
    call wrap_fields_3D(array, nx, ny, layers)
  else
    array = default
  end if

  return
end subroutine read_input_fileV

! ---------------------------------------------------------------------------

subroutine read_input_file_time_series(name, array, default, nTimeSteps)
  implicit none

  character(60), intent(in) :: name
  double precision, intent(out) :: array(nTimeSteps)
  double precision, intent(in) :: default
  integer, intent(in) :: nTimeSteps

  if (name.ne.'') then
    open(unit=10, form='unformatted', file=name)
    read(10) array
    close(10)
  else
    array = default
  end if

  return
end subroutine read_input_file_time_series

!-----------------------------------------------------------------
!> Wrap 3D fields around for periodic boundary conditions

subroutine wrap_fields_3D(array, nx, ny, layers)
  implicit none

  double precision, intent(inout) :: array(0:nx+1, 0:ny+1, layers)
  integer, intent(in) :: nx, ny, layers

  ! wrap array around for periodicity
  array(0, :, :) = array(nx, :, :)
  array(nx+1, :, :) = array(1, :, :)
  array(:, 0, :) = array(:, ny, :)
  array(:, ny+1, :) = array(:, 1, :)

  return
end subroutine wrap_fields_3D

!-----------------------------------------------------------------
!> Wrap 2D fields around for periodic boundary conditions

subroutine wrap_fields_2D(array, nx, ny)
  implicit none

  double precision, intent(inout) :: array(0:nx+1, 0:ny+1)
  integer, intent(in) :: nx, ny

  ! wrap array around for periodicity
  array(0, :) = array(nx, :)
  array(nx+1, :) = array(1, :)
  array(:, 0) = array(:, ny)
  array(:, ny+1) = array(:, 1)

  return
end subroutine wrap_fields_2D

!-----------------------------------------------------------------
!> Write snapshot output of 3d field

subroutine write_output_3d(array, nx, ny, layers, xstep, ystep, &
    n, name)
  implicit none

  double precision, intent(in) :: array(0:nx+1, 0:ny+1, layers)
  integer,          intent(in) :: nx, ny, layers, xstep, ystep
  integer,          intent(in) :: n
  character(*),     intent(in) :: name

  character(10)  :: num

  write(num, '(i10.10)') n

  ! Output the data to a file
  open(unit=10, status='replace', file=name//num, &
      form='unformatted')
  write(10) array(1:nx+xstep, 1:ny+ystep, :)
  close(10)

  return
end subroutine write_output_3d

!-----------------------------------------------------------------
!> Write snapshot output of 3d field

subroutine write_checkpoint_output(array, nx, ny, layers, &
    n, name)
  implicit none

  double precision, intent(in) :: array(0:nx+1, 0:ny+1, layers)
  integer,          intent(in) :: nx, ny, layers
  integer,          intent(in) :: n
  character(*),     intent(in) :: name

  character(10)  :: num

  write(num, '(i10.10)') n

  ! Output the data to a file
  open(unit=10, status='replace', file=name//num, &
      form='unformatted')
  write(10) array
  close(10)

  return
end subroutine write_checkpoint_output

!-----------------------------------------------------------------
!> Write snapshot output of 2d field

subroutine write_output_2d(array, nx, ny, xstep, ystep, &
    n, name)
  implicit none

  double precision, intent(in) :: array(0:nx+1, 0:ny+1)
  integer,          intent(in) :: nx, ny, xstep, ystep
  integer,          intent(in) :: n
  character(*),     intent(in) :: name

  character(10)  :: num
  
  write(num, '(i10.10)') n

  ! Output the data to a file
  open(unit=10, status='replace', file=name//num, &
      form='unformatted')
  write(10) array(1:nx+xstep, 1:ny+ystep)
  close(10)

  return
end subroutine write_output_2d


!-----------------------------------------------------------------
!> create a diagnostics file

subroutine create_diag_file(layers, filename, arrayname, niter0)
  implicit none

  integer,          intent(in) :: layers
  character(*),     intent(in) :: filename
  character(*),     intent(in) :: arrayname
  integer,          intent(in) :: niter0

  integer        :: k
  logical        :: lex
  character(2)   :: layer_number
  character(17)   :: header((4*layers)+1)


  ! prepare header for file
  header(1) = 'timestep'
  do k = 1, layers
    write(layer_number, '(i2.2)') k
    header(2+(4*(k-1))) = 'mean'//layer_number
    header(3+(4*(k-1))) = 'max'//layer_number
    header(4+(4*(k-1))) = 'min'//layer_number
    header(5+(4*(k-1))) = 'std'//layer_number
  end do

  INQUIRE(file=filename, exist=lex)

  if (niter0 .eq. 0) then
    ! starting a nw run, intialise diagnostics files, but warn if 
    ! they were already there
    if (lex) then
      print "(A)", &
        "Starting a new run (niter0=0), but diagnostics file for "//arrayname//" already exists. Overwriting old file."
    else if (.not. lex) then
      print "(A)", &
        "Diagnostics file for "//arrayname//" does not exist. Creating it now."
    end if

    open(unit=10, status='replace', file=filename, &
      form='formatted')
    write (10,'(*(G0.4,:,","))') header
    close(10)

  else if (niter0 .ne. 0) then
    ! restarting from checkpoint, diagnostics file may or may not exist.
    if (lex) then
      print "(A)", &
        "Diagnostics file for "//arrayname//" already exists. Appending to it."
    else if (.not. lex) then
      print "(A)", &
        "Diagnostics file for "//arrayname//" does not exist. Creating it now."

      open(unit=10, status='new', file=filename, &
        form='formatted')
      write (10,'(*(G0.4,:,","))') header
      close(10)
    end if
  end if

  return
end subroutine create_diag_file

!-----------------------------------------------------------------
!> Save diagnostistics of given fields

subroutine write_diag_output(array, nx, ny, layers, &
    n, filename)
  implicit none

  double precision, intent(in) :: array(0:nx+1, 0:ny+1, layers)
  integer,          intent(in) :: nx, ny, layers
  integer,          intent(in) :: n
  character(*),     intent(in) :: filename

  double precision :: diag_out(4*layers)
  integer          :: k

  ! prepare data for file
  do k = 1, layers
    diag_out(1+(4*(k-1))) = sum(array(:,:,k))/dble(size(array(:,:,k))) ! mean
    diag_out(2+(4*(k-1))) = maxval(array(:,:,k))
    diag_out(3+(4*(k-1))) = minval(array(:,:,k))
    diag_out(4+(4*(k-1))) = sqrt( sum( (array(:,:,k) - diag_out(1+(4*(k-1))))**2)/ &
                          dble(size(array(:,:,k))))
  end do

  ! Output the data to a file
  open(unit=10, status='old', file=filename, &
      form='formatted', position='append')
  write (10,'(i10.10, ",", *(G22.15,:,","))') n, diag_out
  close(10)

  return
end subroutine write_diag_output

!-----------------------------------------------------------------
!> finalise MPI and then stop the model

subroutine clean_stop(n, happy)
  implicit none

  integer, intent(in) :: n
  logical, intent(in) :: happy
  
  integer :: ierr

  if (happy) then
    call MPI_Finalize(ierr)
    stop
  else
    print "(A, I0, A, I0, A)", "Unexpected termination at time step ", n
    call MPI_Finalize(ierr)
    stop 1
  end if

  return
end subroutine clean_stop
