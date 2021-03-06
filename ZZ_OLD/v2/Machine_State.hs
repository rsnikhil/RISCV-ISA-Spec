-- Copyright (c) 2018 Rishiyur S. Nikhil
-- See LICENSE for license details

module Machine_State where

-- ================================================================
-- This module defines the data structure holding the RISC-V CPU archtectural state
-- (plus some additional state for debugging/tracing convience)
-- and a read/write API to read and write components of the state.
-- Also defines 'ifetch' (instruction fetch).

-- ================================================================
-- Standard Haskell imports

import Data.Maybe
import Data.Int
import Data.Word
import Data.Bits
import qualified Data.Map as Data_Map
import Numeric (showHex, readHex)

-- Project imports

import Bit_Manipulation
import Arch_Defs
import GPR_File
import CSR_File
import Mem_Ops
import Memory
import MMIO
import Address_Map

-- ================================================================
-- Architectural State data structure.
-- This is a private internal representation that can be changed at
-- will; only the exported API can be used by clients.       \begin_latex{Machine_State}

data Machine_State =
  Machine_State { -- Architectural state
                  f_pc   :: Word64,
                  f_gprs :: GPR_File,
                  f_csrs :: CSR_File,
                  f_priv :: Priv_Level,

                  -- Memory and mory mapped IO
                  f_mem  :: Mem,
                  f_mmio :: MMIO,

                  -- Implementation options
                  f_mem_addr_ranges :: [(Word64, Word64)],    -- list of (addr_start, addr_lim)

                  -- For convenience and debugging only; no semantic relevance
                  f_rv        :: RV,   -- redundant copy of info in CSR MISA
                  f_verbosity :: Int,
                  f_run_state :: Run_State
                }
                                                          -- \end_latex{Machine_State}
data Run_State = Run_State_Running
               | Run_State_WFI        -- Paused waiting for interrupt
  deriving (Eq, Show)

mstate_print :: String -> Machine_State -> IO ()
mstate_print  indent  mstate = do
  let pc   = f_pc    mstate
      gprs = f_gprs  mstate
      csrs = f_csrs  mstate
      priv = f_priv  mstate

      rv        = f_rv    mstate
      run_state = f_run_state  mstate
  
  putStrLn (indent ++ show rv ++ " pc:" ++ showHex pc " priv:" ++ show priv)
  print_GPR_File  indent  gprs
  print_CSR_File  indent  rv  csrs
  -- We do not print memory or MMIO
  putStrLn (indent ++ (show run_state))

-- ================================================================
-- API to create, read/write components of the Architectural State

                                                              -- \begin_latex{Machine_State_constructor}
-- Make a Machine_State, given initial PC and memory contents
mkMachine_State :: RV -> Word64 -> [(Word64,Word64)] -> ([(Int, Word8)]) -> Machine_State
mkMachine_State  rv  initial_PC  addr_ranges  addr_byte_list =
  Machine_State {f_pc   = initial_PC,
                 f_gprs = mkGPR_File,
                 f_csrs = mkCSR_File  rv,
                 f_priv = m_Priv_Level,

                 f_mem             = mkMem  addr_byte_list,
                 f_mmio            = mkMMIO,
                 f_mem_addr_ranges = addr_ranges,

                 f_rv        = rv,
                 f_verbosity = 0,
                 f_run_state = Run_State_Running}
                                                              -- \end_latex{Machine_State_constructor}
-- ----------------
-- read/write PC                                                 \begin_latex{PC_access}

mstate_pc_read :: Machine_State -> Word64
mstate_pc_read  mstate = f_pc mstate

mstate_pc_write :: Machine_State -> Word64 -> Machine_State
mstate_pc_write  mstate  val = mstate { f_pc = val }
                                                              -- \end_latex{PC_access}
-- ----------------
-- read/write RV

mstate_rv_read :: Machine_State -> RV
mstate_rv_read  mstate = f_rv  mstate

mstate_rv_write :: Machine_State -> RV -> Machine_State
mstate_rv_write  mstate  rv = mstate { f_rv = rv }

mstate_xlen_read :: Machine_State -> Int
mstate_xlen_read  mstate | f_rv  mstate == RV32 = 32
                         | f_rv  mstate == RV64 = 64

-- ----------------
-- read/write GPRs

mstate_gpr_read :: Machine_State -> GPR_Addr -> Word64
mstate_gpr_read  mstate  reg = gpr_read (f_gprs mstate)  reg
                                                              -- \begin_latex{mstate_gpr_write}
mstate_gpr_write :: Machine_State -> GPR_Addr -> Word64 -> Machine_State
mstate_gpr_write  mstate  reg  val =
  let
    rv      = f_rv  mstate
    val1 | rv == RV32 = signExtend  val  32
         | rv == RV64 = val
    gprs    = f_gprs  mstate
    gprs'   = gpr_write  gprs  reg  val1
    mstate' = mstate { f_gprs = gprs' }
  in
    mstate'
                                                              -- \end_latex{mstate_gpr_write}

-- ----------------
-- read/write CSRs
-- Assumes CSR exists and access is legal

-- Checks permissions (None, RO, RW) of a csr_addr at a given privilege level
mstate_csr_read_permission :: Machine_State -> Priv_Level -> CSR_Addr -> CSR_Permission
mstate_csr_read_permission  mstate  priv  csr_addr =
  csr_permission  (f_csrs  mstate)  priv  csr_addr

mstate_csr_read :: Machine_State -> CSR_Addr -> Word64
mstate_csr_read  mstate  csr_addr = csr_read  (f_rv  mstate)  (f_csrs  mstate)  csr_addr

mstate_csr_write :: Machine_State -> CSR_Addr -> Word64 -> Machine_State
mstate_csr_write  mstate  csr_addr  value =
  let
    csr_file' = csr_write  (f_rv  mstate)  (f_csrs  mstate)  csr_addr  value
    mstate'   = mstate { f_csrs = csr_file' }
  in
    mstate'

-- ================================================================
-- read/write current privilege level

mstate_priv_read :: Machine_State -> Priv_Level
mstate_priv_read  mstate = f_priv  mstate

mstate_priv_write :: Machine_State -> Priv_Level -> Machine_State
mstate_priv_write  mstate  priv = mstate { f_priv = priv }

-- ================================================================
-- Memory access
-- API functions use address to invoke either memory or memory-mapped I/O devices
-- Note: we compute a new mem state even on reads since they can have side-effects
--   - Memory may change state of PTEs, memory-model tracking, cache coherence, ...
--   - I/O devices may also change device-internal state)

-- Check if the address is supported

is_supported_addr :: Machine_State -> InstrField -> Word64 -> Bool
is_supported_addr  mstate  funct3  addr =
  let
    size | (funct3 == funct3_LB)  = 1
         | (funct3 == funct3_LBU) = 1
         | (funct3 == funct3_LH)  = 2
         | (funct3 == funct3_LHU) = 2
         | (funct3 == funct3_LW)  = 4
         | (funct3 == funct3_LWU) = 4
         | (funct3 == funct3_LD)  = 8
    addr_lim = addr + size

    check [] = False
    check ((astart,alim):ranges) | ((addr >= astart) && (addr_lim <= alim)) = True
                                 | True                                     = check  ranges

    addr_ranges = f_mem_addr_ranges  mstate
  in
    check  addr_ranges

-- Reads

mstate_mem_read :: Machine_State -> Exc_Code -> InstrField -> Word64 -> (Mem_Result, Machine_State)
mstate_mem_read  mstate  exc_code_access_fault  funct3  addr =
  if not (is_supported_addr  mstate  funct3  addr)
  then
    -- Memory access fault
    let
      load_result = Mem_Result_Err  exc_code_access_fault
    in
      (load_result, mstate)

  else if not (is_IO_addr  addr) then
    -- Memory access
    let (load_result, mem') = mem_read  (f_mem mstate)  funct3  addr
        mstate' = (mstate  { f_mem = mem'})
    in
      (load_result, mstate')

  else
    -- MMIO access
    let (load_result, mmio') = mmio_read  (f_mmio mstate)  funct3  addr
    in
      (load_result, (mstate { f_mmio = mmio'}))

-- Writes

mstate_mem_write :: Machine_State -> InstrField -> Word64 -> Word64 -> (Mem_Result, Machine_State)
mstate_mem_write  mstate  funct3  addr  val =
  if not (is_supported_addr  mstate  funct3  addr)
  then
    -- Memory access fault
    let
      load_result = Mem_Result_Err  exc_code_store_AMO_access_fault
    in
      (load_result, mstate)

  else if not (is_IO_addr  addr) then
    -- Memory access
    let (store_result, mem') = mem_write  (f_mem mstate)  funct3  addr  val
    in
      (store_result, mstate { f_mem = mem'})

  else
    -- MMIO access
    let
      (store_result, mmio') = mmio_write  (f_mmio  mstate)  funct3  addr  val
      mstate1               = mstate { f_mmio = mmio' }
    in
      (store_result, mstate1)

-- Atomic Memory Ops

mstate_mem_amo :: Machine_State ->
                     Word64        ->    -- addr
                     InstrField    ->    -- funct3
                     InstrField    ->    -- msbs5
                     InstrField    ->    -- aq
                     InstrField    ->    -- rl
                     Word64        ->    -- store-val
                     (Mem_Result, Machine_State)
mstate_mem_amo  mstate  addr  funct3  msbs5  aq  rl  st_val =
  if not (is_supported_addr  mstate  funct3  addr)
  then
    -- Memory access fault
    let
      load_result = Mem_Result_Err  exc_code_store_AMO_access_fault
    in
      (load_result, mstate)

  else if not (is_IO_addr  addr) then
    -- Memory access
    let (load_result, mem') = mem_amo  (f_mem mstate)  addr  funct3  msbs5  aq  rl  st_val
    in
      (load_result, mstate { f_mem = mem'})

  else
    -- MMIO access
    let (load_result, mmio') = mmio_amo  (f_mmio mstate)  addr  funct3  msbs5  aq  rl  st_val
    in
      (load_result, (mstate { f_mmio = mmio'}))

-- Fences
-- TODO: currently no-ops; fixup when we handle concurrency

mstate_mem_fence  :: Machine_State -> Machine_State
mstate_mem_fence  mstate = mstate

mstate_mem_fence_i  :: Machine_State -> Machine_State
mstate_mem_fence_i  mstate = mstate

mstate_mem_sfence_vm  :: Machine_State -> Word64 -> Word64 -> Machine_State
mstate_mem_sfence_vm  mstate  rs1_val  rs2_val = mstate

-- I/O: enq (CPU <- MMIO <- UART <- tty) console input

mstate_mem_enq_console_input :: Machine_State -> String -> Machine_State
mstate_mem_enq_console_input  mstate  s =
  let
    mmio                    = f_mmio  mstate
    mmio'                   = mmio_enq_console_input  mmio  s
    mstate'                 = mstate { f_mmio = mmio' }
  in
    mstate'

-- I/O: deq (CPU -> MMIO -> UART -> tty) console output

mstate_mem_deq_console_output :: Machine_State -> (String, Machine_State)
mstate_mem_deq_console_output  mstate =
  let
    mmio                    = f_mmio  mstate
    (console_output, mmio') = mmio_deq_console_output  mmio
    mstate'                 = if (console_output == "") then mstate
                              else mstate { f_mmio = mmio' }
  in
    (console_output, mstate')

-- I/O: Read all console input

mstate_mem_all_console_input :: Machine_State -> (String, String)
mstate_mem_all_console_input  mstate =
  let
    mmio = f_mmio  mstate
  in
    mmio_all_console_input  mmio

-- I/O: Read all console output

mstate_mem_all_console_output :: Machine_State -> (String, String)
mstate_mem_all_console_output  mstate =
  let
    mmio = f_mmio  mstate
  in
    mmio_all_console_output  mmio

-- I/O: Tick
--     incr CSR.MCYCLE
--     incr MMIO.MTIME

mstate_mem_tick :: Machine_State -> Machine_State
mstate_mem_tick  mstate =
  let
    rv    = f_rv    mstate
    csrs  = f_csrs  mstate
    mmio  = f_mmio  mstate

    -- Tick CSR.MCYCLE
    csrs1  = (let
                 mcycle = csr_read   rv  csrs  csr_addr_mcycle
                 csrs'  = csr_write  rv  csrs  csr_addr_mcycle  (mcycle + 1)
              in
                 csrs')

    -- Tick memory-mapped location MMIO.MTIME
    mmio1  = mmio_tick_mtime  mmio

    -- Set MIP.MEIP, MIP.MTIP and MIP.MSIP if these interrupts are present
    mip_old = csr_read   rv  csrs1  csr_addr_mip
    eip_old = testBit  mip_old  mip_meip_bitpos
    tip_old = testBit  mip_old  mip_mtip_bitpos
    sip_old = testBit  mip_old  mip_msip_bitpos

    (eip_new, tip_new, sip_new) = mmio_has_interrupts  mmio1

    csrs2 = if ((eip_new == eip_old) && (tip_new == tip_old) && (sip_new == sip_old)) then
              csrs1
            else
              (let
                  mip1 = if (eip_new) then (mip_old  .|.  (shiftL  1  mip_meip_bitpos))
                         else              (mip_old  .&.  (complement (shiftL  1  mip_meip_bitpos)))

                  mip2 = if (tip_new) then (mip1  .|.  (shiftL  1  mip_mtip_bitpos))
                         else              (mip1  .&.  (complement (shiftL  1  mip_mtip_bitpos)))

                  mip3 = if (sip_new) then (mip2  .|.  (shiftL  1  mip_msip_bitpos))
                         else              (mip2  .&.  (complement (shiftL  1  mip_msip_bitpos)))
               in
                  csr_write  rv  csrs1  csr_addr_mip  mip3)

    mstate1 = mstate { f_mmio = mmio1, f_csrs = csrs2 }
  in
    mstate1

-- I/O: convenience function to read mtime
-- (instead of using mstate_mem_read, which can raise exceptions etc.)

mstate_mem_read_mtime :: Machine_State -> Word64
mstate_mem_read_mtime  mstate = mmio_read_mtime  (f_mmio  mstate)

-- ----------------
-- For debugging only
-- Returns number of entries in the Data.Map

mstate_mem_num_entries :: Machine_State -> Int
mstate_mem_num_entries  mstate =
  let
    mem = f_mem  mstate
  in
    mem_num_entries  mem

-- ================================================================
-- read/write misc debug convenience

mstate_verbosity_read :: Machine_State -> Int
mstate_verbosity_read  mstate = f_verbosity mstate

mstate_verbosity_write :: Machine_State -> Int -> Machine_State
mstate_verbosity_write  mstate  verbosity = mstate { f_verbosity = verbosity }

mstate_run_state_read :: Machine_State -> Run_State
mstate_run_state_read  mstate = f_run_state  mstate

mstate_run_state_write :: Machine_State -> Run_State -> Machine_State
mstate_run_state_write  mstate  run_state = mstate { f_run_state = run_state }

-- ================================================================
