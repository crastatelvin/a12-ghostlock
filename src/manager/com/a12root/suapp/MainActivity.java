package com.a12root.suapp;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;

/** A12 root manager: root status plus a KernelSU-style module screen. */
public class MainActivity extends Activity {
    private static final int PICK_ZIP = 1001;

    private TextView status;
    private TextView out;
    private LinearLayout list;
    private final Handler h = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        float d = getResources().getDisplayMetrics().density;
        int p = (int) (16 * d);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(p, (int) (40 * d), p, p);

        TextView title = new TextView(this);
        title.setTextSize(20);
        title.setText("A12 Root Manager");

        status = new TextView(this);
        status.setTextSize(13);
        status.setTextIsSelectable(true);
        status.setPadding(0, p / 2, 0, p / 2);

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);

        Button check = new Button(this);
        check.setText("Root check");
        check.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                checkRoot();
            }
        });

        Button install = new Button(this);
        install.setText("Install module (.zip)");
        install.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                pickZip();
            }
        });

        bar.addView(check, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        bar.addView(install, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.6f));

        TextView mh = new TextView(this);
        mh.setTextSize(16);
        mh.setPadding(0, p, 0, p / 2);
        mh.setText("Modules");

        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);

        out = new TextView(this);
        out.setTextSize(12);
        out.setTextIsSelectable(true);
        out.setPadding(0, p, 0, p);

        root.addView(title);
        root.addView(status);
        root.addView(bar);
        root.addView(mh);
        root.addView(list);
        root.addView(out);

        ScrollView sc = new ScrollView(this);
        sc.addView(root);
        setContentView(sc);

        checkRoot();
    }

    private interface Callback {
        void done(String r);
    }

    private void su(final String cmd, final Callback cb) {
        new Thread(new Runnable() {
            public void run() {
                final String r = execSu(cmd);
                h.post(new Runnable() {
                    public void run() {
                        cb.done(r);
                    }
                });
            }
        }).start();
    }

    private static String execSu(String cmd) {
        String[] paths = {"/system_ext/bin/su", "su"};
        String last = "su not found";
        for (String path : paths) {
            try {
                ProcessBuilder pb = new ProcessBuilder(path, "-c", cmd);
                pb.redirectErrorStream(true);
                Process p = pb.start();
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String s;
                while ((s = r.readLine()) != null) sb.append(s).append('\n');
                int rc = p.waitFor();
                if (rc == 0 || sb.length() > 0) return sb.toString();
                last = path + " exit=" + rc;
            } catch (Exception e) {
                last = path + ": " + e;
            }
        }
        return last;
    }

    private void checkRoot() {
        status.setText("checking root...");
        su("id; echo ---; su -v; ksud --version; magisk -v", new Callback() {
            public void done(String r) {
                status.setText(r.trim());
                refreshModules();
            }
        });
    }

    private void refreshModules() {
        out.setText("loading modules...");
        su("ksud module list 2>&1", new Callback() {
            public void done(String r) {
                renderModules(r);
            }
        });
    }

    private void renderModules(String raw) {
        list.removeAllViews();
        int a = raw.indexOf('[');
        int z = raw.lastIndexOf(']');
        if (a < 0 || z < a) {
            out.setText("module list failed:\n" + raw);
            return;
        }
        try {
            JSONArray arr = new JSONArray(raw.substring(a, z + 1));
            if (arr.length() == 0) {
                TextView none = new TextView(this);
                none.setText("No modules installed.");
                list.addView(none);
            }
            for (int i = 0; i < arr.length(); i++) {
                addRow(arr.getJSONObject(i));
            }
            out.setText("Loaded " + arr.length() + " module(s).");
        } catch (Exception e) {
            out.setText("module list parse error: " + e + "\n" + raw);
        }
    }

    private void addRow(final JSONObject m) {
        final String id = m.optString("id");
        boolean enabled = m.optBoolean("enabled", true);
        boolean action = m.optBoolean("action", false);

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(0, (int) (8 * getResources().getDisplayMetrics().density), 0,
                (int) (8 * getResources().getDisplayMetrics().density));

        TextView title = new TextView(this);
        title.setTextSize(15);
        title.setText(m.optString("name") + " " + m.optString("version") +
                (enabled ? "" : "  [disabled]"));
        TextView sub = new TextView(this);
        sub.setTextSize(12);
        sub.setText(id + "  by " + m.optString("author") + "\n" + m.optString("description"));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);

        Button toggle = new Button(this);
        toggle.setText(enabled ? "Disable" : "Enable");
        toggle.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                moduleCmd("ksud module " + (enabled ? "disable " : "enable ") + id);
            }
        });

        row.addView(toggle);

        if (action) {
            Button act = new Button(this);
            act.setText("Action");
            act.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) {
                    moduleCmd("ksud module action " + id);
                }
            });
            row.addView(act);
        }

        Button del = new Button(this);
        del.setText("Uninstall");
        del.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                confirmUninstall(id);
            }
        });
        row.addView(del);

        box.addView(title);
        box.addView(sub);
        box.addView(row);
        list.addView(box);
    }

    private void moduleCmd(String cmd) {
        out.setText("running: " + cmd);
        su(cmd + " 2>&1", new Callback() {
            public void done(String r) {
                out.setText(r.trim());
                refreshModules();
            }
        });
    }

    private void confirmUninstall(final String id) {
        new AlertDialog.Builder(this)
                .setTitle("Uninstall " + id + "?")
                .setMessage("The module directory and its overlay are removed now.")
                .setPositiveButton("Uninstall", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        moduleCmd("ksud module uninstall " + id);
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void pickZip() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        try {
            startActivityForResult(i, PICK_ZIP);
        } catch (Exception e) {
            Toast.makeText(this, "No document picker: " + e, Toast.LENGTH_LONG).show();
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != PICK_ZIP || res != RESULT_OK || data == null || data.getData() == null) return;
        final Uri uri = data.getData();
        out.setText("copying module zip...");
        new Thread(new Runnable() {
            public void run() {
                String msg;
                File dst = new File(getCacheDir(), "module.zip");
                try {
                    InputStream in = getContentResolver().openInputStream(uri);
                    FileOutputStream fo = new FileOutputStream(dst);
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) fo.write(buf, 0, n);
                    in.close();
                    fo.close();
                    msg = execSu("ksud module install '" + dst.getAbsolutePath() + "' 2>&1");
                } catch (Exception e) {
                    msg = "copy failed: " + e;
                }
                final String r = msg;
                h.post(new Runnable() {
                    public void run() {
                        out.setText(r.trim());
                        refreshModules();
                    }
                });
            }
        }).start();
    }
}
