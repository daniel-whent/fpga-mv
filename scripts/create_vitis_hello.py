r"""Create the Vitis platform + hello app for the Nexys A7-100T MicroBlaze system and build both.

Run from cmd.exe. Vivado's settings must be loaded too, because Vitis calls Vivado's
sdtgen to turn the .xsa into a system device tree (without it: "Error in generating SDT"):
    call C:\AMDDesignTools\2025.2\Vivado\settings64.bat
    call C:\AMDDesignTools\2025.2\Vitis\settings64.bat
    vitis -s C:\Users\daniel.whent\workspace\machine-vision\scripts\create_vitis_hello.py

Select the program with env APP (default hello) and APP_DIR (software/<APP_DIR>/src, default = APP);
e.g. set APP=ddr2_test before running. Workspace defaults to C:/tmp/fpga-mv-ws (override with env VITIS_WS). ELF: <workspace>/hello/build/hello.elf

Needs hw_export/system_wrapper.xsa (made by scripts/export_xsa.tcl in Vivado).
Modeled on <Vitis>/cli/examples/embedded/platform_uc5_MB.py.
"""
import os
import shutil
import stat
import vitis

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
xsa = os.path.join(repo, "hw_export", "system_wrapper.xsa")
workspace = os.path.normpath(os.environ.get("VITIS_WS", "C:/tmp/fpga-mv-ws"))
APP = os.environ.get("APP", "hello")
app_src_dir = os.path.join(repo, "software", os.environ.get("APP_DIR", APP), "src")

PLATFORM = "nexys_platform"

if not os.path.isfile(xsa):
    raise SystemExit(f"Missing {xsa}. Run scripts/export_xsa.tcl in Vivado first.")

def _make_writable_and_retry(func, path, _exc):
    # Vitis leaves some generated files read-only; Windows refuses to delete them otherwise.
    os.chmod(path, stat.S_IWRITE)
    func(path)

if os.path.isdir(workspace):
    shutil.rmtree(workspace, onexc=_make_writable_and_retry)

client = vitis.create_client()
client.set_workspace(workspace)

platform = client.create_platform_component(name=PLATFORM, hw_design=xsa)
platform.add_domain(name="microblaze", cpu="microblaze_0", os="standalone")
platform.build()

xpfm = client.find_platform_in_repos(PLATFORM)
app = client.create_app_component(
    name=APP, platform=xpfm, domain="microblaze", template="empty_application"
)
app.import_files(from_loc=app_src_dir, files=["main.c"])
app.build()

print(f"Built. ELF: look under {os.path.join(workspace, APP)}/build/")
vitis.dispose()
