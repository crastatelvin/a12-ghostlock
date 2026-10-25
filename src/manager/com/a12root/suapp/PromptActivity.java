package com.a12root.suapp;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.text.method.ScrollingMovementMethod;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.FileOutputStream;
import java.io.FileReader;

/** KernelSU-style grant dialog.  Started by the root daemon; answers by
 *  writing /data/local/tmp/a12su/ans_<req>. */
public class PromptActivity extends Activity {
    private static final String DIR = "/data/local/tmp/a12su";
    private static final long TIMEOUT_MS = 30000;

    private String req;
    private final Handler h = new Handler(Looper.getMainLooper());
    private final Runnable timeout = new Runnable() {
        public void run() { answer("deny"); }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setFinishOnTouchOutside(false);
        show(getIntent());
    }

    @Override
    protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        setIntent(i);
        show(i);
    }

    private void show(Intent i) {
        h.removeCallbacks(timeout);
        req = i == null ? null : i.getStringExtra("req");

        int uid = -1;
        String cmd = "(no request)";
        if (req != null) {
            BufferedReader r = null;
            try {
                r = new BufferedReader(new FileReader(DIR + "/req_" + req));
                String l;
                while ((l = r.readLine()) != null) {
                    if (l.startsWith("uid=")) {
                        try { uid = Integer.parseInt(l.substring(4).trim()); }
                        catch (Exception ignored) {}
                    } else if (l.startsWith("cmd=")) {
                        cmd = l.substring(4);
                    }
                }
            } catch (Exception e) {
                cmd = "(request expired)";
            } finally {
                try { if (r != null) r.close(); } catch (Exception ignored) {}
            }
        }

        float d = getResources().getDisplayMetrics().density;
        int p = (int) (18 * d);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(p, p, p, p);

        TextView title = new TextView(this);
        title.setText("Root access request");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setPadding(0, 0, 0, (int) (8 * d));
        root.addView(title);

        TextView app = new TextView(this);
        app.setText(describe(uid) + "\nUID " + uid + "  |  su request");
        app.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        app.setPadding(0, 0, 0, (int) (10 * d));
        root.addView(app);

        TextView body = new TextView(this);
        body.setText(cmd);
        body.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        body.setTypeface(Typeface.MONOSPACE);
        body.setTextIsSelectable(true);
        body.setMaxLines(8);
        body.setVerticalScrollBarEnabled(true);
        body.setMovementMethod(new ScrollingMovementMethod());
        body.setBackgroundColor(0x22808080);
        body.setPadding((int) (8 * d), (int) (8 * d), (int) (8 * d), (int) (8 * d));
        root.addView(body);

        TextView note = new TextView(this);
        note.setText("Always allow stores a rule in /data/local/tmp/a12su/policy.");
        note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        note.setPadding(0, (int) (10 * d), 0, (int) (12 * d));
        root.addView(note);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.END);
        row.addView(button("Deny", "deny", row, d));
        row.addView(button("Allow", "allow", row, d));
        row.addView(button("Always allow", "always", row, d));
        root.addView(row);

        setContentView(root);
        if (getWindow() != null) {
            getWindow().setLayout((int) (320 * d), LinearLayout.LayoutParams.WRAP_CONTENT);
        }
        h.postDelayed(timeout, TIMEOUT_MS);
    }

    private Button button(String label, final String answer, LinearLayout row, float d) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins((int) (6 * d), 0, 0, 0);
        b.setLayoutParams(lp);
        b.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { answer(answer); }
        });
        return b;
    }

    private String describe(int uid) {
        if (uid < 0) return "Unknown app";
        PackageManager pm = getPackageManager();
        String[] pkgs = pm.getPackagesForUid(uid);
        if (pkgs == null || pkgs.length == 0) return "uid " + uid;
        StringBuilder sb = new StringBuilder();
        for (String p : pkgs) {
            String label = p;
            try {
                ApplicationInfo ai = pm.getApplicationInfo(p, 0);
                label = pm.getApplicationLabel(ai).toString();
            } catch (Exception ignored) {}
            if (sb.length() > 0) sb.append(", ");
            sb.append(label).append(" (").append(p).append(")");
        }
        return sb.toString();
    }

    private void answer(String a) {
        h.removeCallbacks(timeout);
        if (!TextUtils.isEmpty(req)) {
            try {
                FileOutputStream f = new FileOutputStream(DIR + "/ans_" + req);
                f.write(a.getBytes("UTF-8"));
                f.close();
            } catch (Exception ignored) {}
        }
        finish();
    }

    @Override
    protected void onDestroy() {
        h.removeCallbacks(timeout);
        super.onDestroy();
    }
}
