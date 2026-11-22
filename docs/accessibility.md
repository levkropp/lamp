# Windows control accessibility

The Windows player uses native buttons and trackbars over its assembly canvas. Buttons expose their window text, including changing Play/Pause and Repeat names. Playback position and volume expose native slider roles and values.

A native Windows inspection found that trackbar window text did not supply an accessible name: the two sliders appeared with values but no names. The player now annotates their client objects as **Playback position** and **Volume**, using Windows' [IAccPropServices::SetHwndPropStr](https://learn.microsoft.com/en-us/windows/win32/api/oleacc/nf-oleacc-iaccpropservices-sethwndpropstr) with `PROPID_ACC_NAME`. It clears those annotations before normal window destruction. Native range, pointer and keyboard behavior remain with the standard trackbar implementation.

The original assembly helper is in `src/win/accessibility.s`. It uses Windows COM services already available to the graphical player, balances its own COM initialization and preserves an existing STA or MTA apartment. It returns the actual HRESULT; an annotation failure does not prevent playback. It is linked only into the Windows graphical player and its UI test executables. Neither the console nor the Mac/Linux backends use it.

## Verification

Build the Windows binaries, then run the SDK-based test oracle:

```powershell
.\build.ps1 -OutputDirectory .\bin\accessibility-check -Tests
.\tests\verify-windows-accessibility.ps1 -OutputDirectory .\bin\accessibility-check
```

Normal player builds require LLVM and Python. This optional native test additionally needs Visual Studio x64 C++ Build Tools and a Windows SDK. Its C code is linked only into a test executable.

The [recorded native report](../reports/windows-accessibility-verification.json) passes 452 checks: both labels, Unicode name replacement, value retention, removal, 64 control lifecycles in STA/MTA callers, and initialization/cleanup without a caller apartment. It reads actual `IAccessible::get_accName` values from hidden native controls. It creates no visible window and sends no keyboard or mouse input to the desktop. The Windows runtime/import checks and six-format PCM smoke tests also pass after the change.

Windows 11 returned `E_INVALIDARG` for all 64 repeated clears after the first successful clear, although [Microsoft documents success for that case](https://learn.microsoft.com/en-us/windows/win32/api/oleacc/nf-oleacc-iaccpropservices-clearhwndprops). The test records that result; the helper preserves it. Initial clears must succeed and remove the annotated name.

These checks establish the native MSAA naming path. The full UI Automation tree after the fix, Narrator/NVDA use, keyboard focus across every player state and mixed-monitor DPI behavior still need interactive verification. The existing Wine checks retain their own platform scope. No complete screen-reader compatibility claim is made.
