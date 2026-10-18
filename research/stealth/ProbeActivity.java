package org.kestrel.emudetect;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.hardware.Sensor;
import android.hardware.SensorManager;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.telephony.TelephonyManager;
import android.util.Log;
import android.provider.Settings;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.lang.reflect.Method;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;

/**
 * Detection-surface probe: enumerates every signal an app could use to
 * conclude it is running on an emulator, and writes a JSON verdict file.
 * Original diagnostic code; reads only, hooks nothing.
 */
public final class ProbeActivity extends Activity {
    private static final String TAG = "EmuDetect";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        new Thread(new Runnable() { @Override public void run() { probe(); } }).start();
    }

    private void probe() {
        JSONObject r = new JSONObject();
        try {
            r.put("schema", 1);
            r.put("ts", System.currentTimeMillis());
            r.put("build", buildFields());
            r.put("props", props());
            r.put("files", files());
            r.put("gles", gles());
            r.put("sensors", sensors());
            r.put("battery", battery());
            r.put("telephony", telephony());
            r.put("cpuinfo", cpuinfo());
            r.put("input_devices", inputFile());
            r.put("network", network());
            r.put("settings", settings());
            r.put("packages", packages());
            r.put("verdict", verdict(r));
        } catch (Exception e) {
            try { r.put("fatal", e.toString()); } catch (Exception ignored) {}
        }
        String out;
        try { out = r.toString(2); } catch (Exception e) { out = "{\"fatal\":\"toString failed: " + e + "\"}"; }
        try (FileOutputStream f = openFileOutput("report.json", MODE_PRIVATE)) {
            f.write(out.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) { Log.e(TAG, "file write failed", e); }
        // Logcat fallback channel, chunked to survive line limits.
        for (int i = 0; i < out.length(); i += 3000) {
            Log.i(TAG, "JSONCHUNK " + out.substring(i, Math.min(out.length(), i + 3000)));
        }
        Log.i(TAG, "JSONEND bytes=" + out.length());
        finish();
    }

    private JSONObject buildFields() throws Exception {
        JSONObject o = new JSONObject();
        String[][] pairs = {
            {"MODEL", Build.MODEL}, {"MANUFACTURER", Build.MANUFACTURER},
            {"BRAND", Build.BRAND}, {"DEVICE", Build.DEVICE},
            {"PRODUCT", Build.PRODUCT}, {"HARDWARE", Build.HARDWARE},
            {"BOARD", Build.BOARD}, {"FINGERPRINT", Build.FINGERPRINT},
            {"BOOTLOADER", Build.BOOTLOADER}, {"TYPE", Build.TYPE},
            {"TAGS", Build.TAGS}, {"USER", Build.USER}, {"HOST", Build.HOST},
            {"DISPLAY", Build.DISPLAY}, {"ID", Build.ID},
            {"SERIAL", safeSerial()}, {"SUPPORTED_ABIS", android.text.TextUtils.join(",", Build.SUPPORTED_ABIS)},
        };
        for (String[] p : pairs) o.put(p[0], p[1]);
        return o;
    }

    private String safeSerial() {
        try { return Build.SERIAL; } catch (Throwable t) { return "restricted:" + t.getClass().getSimpleName(); }
    }

    private JSONObject props() throws Exception {
        JSONObject all = new JSONObject();
        Process p = Runtime.getRuntime().exec(new String[]{"getprop"});
        BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()));
        String line;
        while ((line = br.readLine()) != null) {
            int a = line.indexOf('['), b = line.indexOf("]: [", a + 1), c = line.lastIndexOf(']');
            if (a >= 0 && b > a && c > b) all.put(line.substring(a + 1, b), line.substring(b + 4, c));
        }
        p.waitFor();
        String[] interesting = {
            "ro.kernel.qemu", "ro.kernel.android.qemud", "ro.hardware", "ro.board.platform",
            "ro.build.flavor", "ro.build.type", "ro.build.tags", "ro.build.host",
            "ro.build.characteristics", "ro.build.fingerprint", "ro.build.description",
            "ro.product.device", "ro.product.name", "ro.product.model", "ro.product.brand",
            "ro.product.manufacturer", "ro.product.cpu.abilist", "ro.bootloader",
            "ro.boot.qemu", "ro.boot.goldfish", "ro.boot.hardware", "ro.boot.flash.locked",
            "ro.radio.noril", "gsm.version.baseband", "gsm.sim.state", "gsm.operator.alpha",
            "ro.debuggable", "ro.secure", "ro.adb.secure", "ro.build.version.security_patch",
            "ro.build.version.release", "ro.build.version.sdk", "ro.qemu.initrc",
            "qemu.hw.mainkeys", "qemu.sf.lcd_density", "init.svc.qemu-props",
            "init.svc.goldfish-setup", "ro.kernel.android.checkjni", "persist.qemu.sf.lcd_density",
            "ro.setupwizard.mode", "sys.boot_completed", "ro.crypto.state",
            "ro.build.version.incremental", "ro.revision", "ro.serialno", "ro.boot.serialno",
        };
        JSONObject pick = new JSONObject();
        for (String k : interesting) if (all.has(k)) pick.put(k, all.get(k));
        JSONObject ret = new JSONObject();
        ret.put("interesting", pick);
        ret.put("total_count", all.length());
        JSONArray emuKeys = new JSONArray();
        java.util.Iterator<String> names = all.keys();
        while (names.hasNext()) {
            String k = names.next();
            String v = all.optString(k, "").toLowerCase();
            if (k.contains("qemu") || k.contains("goldfish") || k.contains("nemu") || v.contains("qemu")
                    || v.contains("goldfish") || v.contains("sdk_gphone") || v.contains("emulator")) emuKeys.put(k + "=" + all.optString(k));
        }
        ret.put("emu_signatures", emuKeys);
        return ret;
    }

    private JSONObject files() throws Exception {
        String[] paths = {
            "/dev/qemu_pipe", "/dev/goldfish_pipe", "/dev/socket/qemud", "/dev/qemu_trace",
            "/system/lib/libc_malloc_debug_qemu.so", "/system/lib64/libc_malloc_debug_qemu.so",
            "/system/bin/qemu-props", "/init.goldfish.rc", "/init.qemu.rc",
            "/sys/module/goldfish_audio", "/sys/module/goldfish_battery",
            "/sys/devices/system/qemu_trace", "/proc/qemu_trace",
            "/system/lib64/egl/libEGL_goldfish.so", "/system/lib64/hw/gralloc.ranchu.so",
            "/system/lib64/hw/vulkan.ranchu.so", "/dev/uinput",
            "/system/xbin/su", "/system/bin/su", "/sbin/su",
            "/data/local/tmp",
        };
        JSONObject o = new JSONObject();
        for (String path : paths) o.put(path, new File(path).exists());
        return o;
    }

    private JSONObject gles() {
        JSONObject gl = new JSONObject();
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        EGLContext context = EGL14.EGL_NO_CONTEXT;
        EGLSurface surface = EGL14.EGL_NO_SURFACE;
        try {
            int[] version = new int[2];
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) throw new Exception("eglInitialize failed");
            EGLConfig[] configs = new EGLConfig[1];
            int[] count = new int[1];
            int[] cfg = {EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_RENDERABLE_TYPE,
                EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_NONE};
            if (!EGL14.eglChooseConfig(display, cfg, 0, configs, 0, 1, count, 0) || count[0] == 0)
                throw new Exception("no ES2 pbuffer config");
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
            surface = EGL14.eglCreatePbufferSurface(display, configs[0],
                new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) throw new Exception("eglMakeCurrent failed");
            gl.put("vendor", GLES20.glGetString(GLES20.GL_VENDOR));
            gl.put("renderer", GLES20.glGetString(GLES20.GL_RENDERER));
            gl.put("version", GLES20.glGetString(GLES20.GL_VERSION));
            String exts = GLES20.glGetString(GLES20.GL_EXTENSIONS);
            gl.put("extensions_count", exts == null ? 0 : exts.split(" ").length);
            JSONArray emuExt = new JSONArray();
            if (exts != null) for (String e : exts.split(" ")) {
                if (e.toLowerCase().contains("emulator") || e.toLowerCase().contains("goldfish")
                        || e.toLowerCase().contains("translator") || e.toLowerCase().contains("swiftshader")) emuExt.put(e);
            }
            gl.put("emu_extensions", emuExt);
        } catch (Exception e) {
            try { gl.put("error", e.toString()); } catch (Exception ignored) {}
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface);
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context);
            EGL14.eglTerminate(display);
        }
        return gl;
    }

    private JSONObject sensors() throws Exception {
        SensorManager sm = (SensorManager) getSystemService(Context.SENSOR_SERVICE);
        List<Sensor> list = sm.getSensorList(Sensor.TYPE_ALL);
        JSONObject o = new JSONObject();
        o.put("count", list.size());
        JSONArray names = new JSONArray();
        for (Sensor s : list) names.put(s.getType() + ":" + s.getName() + "/" + s.getVendor());
        o.put("list", names);
        return o;
    }

    private JSONObject battery() throws Exception {
        Intent i = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        JSONObject o = new JSONObject();
        if (i == null) return o;
        int status = i.getIntExtra("status", -1);
        String[] statusNames = {"unknown", "charging", "discharging", "not_charging", "full"};
        o.put("status", statusNames[status >= 0 && status < statusNames.length ? status : 0]);
        o.put("level", i.getIntExtra("level", -1));
        o.put("scale", i.getIntExtra("scale", -1));
        o.put("voltage_mv", i.getIntExtra("voltage", -1));
        o.put("temperature_deci_c", i.getIntExtra("temperature", -1));
        o.put("plugged", i.getIntExtra("plugged", -1));
        o.put("technology", i.getStringExtra("technology"));
        o.put("present", i.getBooleanExtra("present", false));
        return o;
    }

    private JSONObject telephony() throws Exception {
        TelephonyManager t = (TelephonyManager) getSystemService(Context.TELEPHONY_SERVICE);
        JSONObject o = new JSONObject();
        String[] simStates = {"unknown", "absent", "pin_required", "puk_required", "network_locked",
            "ready", "not_ready", "permanently_disabled", "card_io_error", "card_restricted"};
        int st = t.getSimState();
        o.put("sim_state", st >= 0 && st < simStates.length ? simStates[st] : String.valueOf(st));
        o.put("has_icc_card", t.hasIccCard());
        o.put("sim_operator_name", t.getSimOperatorName());
        o.put("network_operator", t.getNetworkOperator());
        o.put("network_operator_name", t.getNetworkOperatorName());
        o.put("phone_type", t.getPhoneType());
        o.put("is_sms_capable", t.isSmsCapable());
        try { o.put("device_id", t.getDeviceId()); } catch (SecurityException e) { o.put("device_id", "denied"); }
        try { o.put("imei_count", t.getImei() == null ? 0 : 1); } catch (Throwable x) { o.put("imei_count", "denied"); }
        return o;
    }

    private JSONObject cpuinfo() throws Exception {
        JSONObject o = new JSONObject();
        StringBuilder raw = new StringBuilder();
        BufferedReader br = new BufferedReader(new FileReader("/proc/cpuinfo"));
        String line; int lines = 0;
        while ((line = br.readLine()) != null && lines < 200) { raw.append(line).append('\n'); lines++; }
        br.close();
        o.put("raw_head", raw.substring(0, Math.min(raw.length(), 2000)));
        JSONArray tells = new JSONArray();
        String lower = raw.toString().toLowerCase();
        for (String needle : new String[]{"goldfish", "qemu", "ranchu", "android", "hypervisor"}) {
            if (lower.contains(needle)) tells.put(needle);
        }
        o.put("signatures_found", tells);
        return o;
    }

    private JSONObject inputFile() throws Exception {
        JSONObject o = new JSONObject();
        StringBuilder raw = new StringBuilder();
        try {
            BufferedReader br = new BufferedReader(new FileReader("/proc/bus/input/devices"));
            String line;
            while ((line = br.readLine()) != null) raw.append(line).append('\n');
            br.close();
        } catch (Exception e) {
            o.put("error", e.toString());
            return o;
        }
        o.put("raw", raw.toString());
        JSONArray tells = new JSONArray();
        String lower = raw.toString().toLowerCase();
        for (String needle : new String[]{"kestrel", "uinput", "goldfish", "qemu", "virtio", "nemu", "mouse", "keyboard"}) {
            if (lower.contains(needle)) tells.put(needle);
        }
        o.put("signatures_found", tells);
        return o;
    }

    private JSONObject network() throws Exception {
        JSONObject o = new JSONObject();
        JSONArray ifs = new JSONArray();
        Enumeration<NetworkInterface> nifs = NetworkInterface.getNetworkInterfaces();
        if (nifs == null) {
            o.put("interfaces", ifs);
            o.put("note", "getNetworkInterfaces() returned null");
            return o;
        }
        for (NetworkInterface nif : Collections.list(nifs)) {
            JSONObject i = new JSONObject();
            i.put("name", nif.getName());
            try {
                byte[] mac = nif.getHardwareAddress();
                if (mac == null) i.put("mac", "null");
                else {
                    StringBuilder sb = new StringBuilder();
                    for (byte b : mac) sb.append(String.format("%02x:", b));
                    i.put("mac", sb.substring(0, sb.length() - 1));
                }
            } catch (Exception e) { i.put("mac", "error:" + e.getClass().getSimpleName()); }
            i.put("up", nif.isUp());
            ifs.put(i);
        }
        o.put("interfaces", ifs);
        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            WifiInfo wi = wm.getConnectionInfo();
            o.put("wifi_mac", wi.getMacAddress());
            o.put("wifi_ssid", wi.getSSID());
        } catch (Exception e) { o.put("wifi_error", e.toString()); }
        return o;
    }

    private JSONObject settings() throws Exception {
        JSONObject o = new JSONObject();
        try { o.put("adb_enabled", Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED)); }
        catch (Exception e) { o.put("adb_enabled", "error"); }
        try { o.put("debug_app", Settings.Global.getInt(getContentResolver(), Settings.Global.DEBUG_APP)); }
        catch (Exception e) { o.put("debug_app", "error"); }
        try {
            Class<?> b = Class.forName("android.os.Build");
            o.put("is_debuggable_reflect", b.getField("IS_DEBUGGABLE").get(null));
        } catch (Throwable t) { o.put("is_debuggable_reflect", "unavailable"); }
        return o;
    }

    private JSONObject packages() throws Exception {
        JSONObject o = new JSONObject();
        String[] suspects = {
            "com.google.android.apps.emulator.head_track", "com.android.emulator",
            "com.google.android.gms.unstable", "com.nemu.goldfish",
        };
        PackageManager pm = getPackageManager();
        for (String s : suspects) {
            try { pm.getPackageInfo(s, 0); o.put(s, true); } catch (PackageManager.NameNotFoundException e) { o.put(s, false); }
        }
        return o;
    }

    private JSONObject verdict(JSONObject r) throws Exception {
        JSONObject v = new JSONObject();
        int leaks = 0;
        JSONObject b = r.getJSONObject("build");
        String hw = b.optString("HARDWARE", "");
        String fp = b.optString("FINGERPRINT", "").toLowerCase();
        String flavor = r.getJSONObject("props").getJSONObject("interesting").optString("ro.build.flavor", "").toLowerCase();
        String type = b.optString("TYPE", "");
        String tags = b.optString("TAGS", "");
        String model = b.optString("MODEL", "");
        String mac = "";
        JSONArray ifs = r.getJSONObject("network").getJSONArray("interfaces");
        for (int i = 0; i < ifs.length(); i++) {
            JSONObject j = ifs.getJSONObject(i);
            if (j.optString("name").startsWith("wlan")) mac = j.optString("mac");
        }
        String renderer = r.getJSONObject("gles").optString("renderer", "");
        int sensorCount = r.getJSONObject("sensors").optInt("count", 0);
        JSONObject batt = r.getJSONObject("battery");
        JSONObject tel = r.getJSONObject("telephony");

        leaks += flag(v, "hardware_is_goldfish_ranchu_or_qemu", hw.contains("goldfish") || hw.contains("ranchu") || hw.contains("qemu"), hw);
        leaks += flag(v, "fingerprint_generic_or_sdk", fp.contains("generic") || fp.contains("sdk_gphone") || fp.contains("emu"), fp);
        leaks += flag(v, "build_flavor_emulator", flavor.contains("emulator") || flavor.contains("sdk_gphone"), flavor);
        leaks += flag(v, "build_type_not_user", !"user".equals(type), type);
        leaks += flag(v, "build_tags_test_keys", tags.contains("test-keys"), tags);
        leaks += flag(v, "model_sdk_gphone", model.toLowerCase().contains("sdk") || model.toLowerCase().contains("emulator"), model);
        leaks += flag(v, "qemu_props_present", r.getJSONObject("props").getJSONObject("emu_signatures").length() > 0,
                r.getJSONObject("props").getJSONObject("emu_signatures").toString());
        leaks += flag(v, "emulator_files_present", anyTrue(r.getJSONObject("files"), new String[]{"/dev/qemu_pipe", "/dev/socket/qemud", "/dev/qemu_trace", "/system/bin/qemu-props"}), "");
        leaks += flag(v, "emulator_gl_renderer", renderer.toLowerCase().contains("emulator") || renderer.toLowerCase().contains("swiftshader") || renderer.toLowerCase().contains("translator") || renderer.toLowerCase().contains("goldfish") || renderer.toLowerCase().contains("android"), renderer);
        leaks += flag(v, "suspiciously_few_sensors", sensorCount > 0 && sensorCount <= 5, "count=" + sensorCount);
        leaks += flag(v, "battery_possibly_fake", "charging".equals(batt.optString("status")) || batt.optInt("temperature_deci_c", 0) == 250, batt.toString());
        leaks += flag(v, "no_telephony", !"ready".equals(tel.optString("sim_state")) && !tel.optBoolean("has_icc_card", false), tel.toString());
        leaks += flag(v, "zero_mac", "02:00:00:00:00:00".equals(mac), mac);
        leaks += flag(v, "adb_enabled", r.getJSONObject("settings").optInt("adb_enabled", 0) == 1, "");
        leaks += flag(v, "input_device_signatures", r.getJSONObject("input_devices").getJSONArray("signatures_found").length() > 0,
                r.getJSONObject("input_devices").getJSONArray("signatures_found").toString());
        leaks += flag(v, "cpuinfo_signatures", r.getJSONObject("cpuinfo").getJSONArray("signatures_found").length() > 0,
                r.getJSONObject("cpuinfo").getJSONArray("signatures_found").toString());
        v.put("leak_count", leaks);
        v.put("clean", leaks == 0);
        return v;
    }

    private int flag(JSONObject v, String name, boolean leak, String detail) throws Exception {
        JSONObject o = new JSONObject();
        o.put("leak", leak);
        if (detail != null && !detail.isEmpty()) o.put("detail", detail);
        v.put(name, o);
        return leak ? 1 : 0;
    }

    private boolean anyTrue(JSONObject files, String[] keys) {
        for (String k : keys) if (files.optBoolean(k, false)) return true;
        return false;
    }
}
