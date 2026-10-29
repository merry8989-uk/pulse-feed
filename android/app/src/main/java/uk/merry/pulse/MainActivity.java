package uk.merry.pulse;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.IntentFilter;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.webkit.ValueCallback;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

public class MainActivity extends Activity {

    private static final String START_URL = "https://merry8989-uk.github.io/pulse-feed/";
    private static final String HOME_HOST = "merry8989-uk.github.io";
    private static final String RELEASES_API =
            "https://api.github.com/repos/merry8989-uk/pulse-feed/releases/latest";
    private static final int FILE_REQ = 1001;

    private WebView web;
    private ValueCallback<Uri[]> filePathCallback;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private AlertDialog updateDialog;
    private ProgressBar updateBar;
    private TextView updateText;
    private long downloadId = -1;
    private PermissionRequest pendingPermRequest;
    private static final int PERM_REQ = 2001;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);

        FrameLayout root = new FrameLayout(this);
        web = new WebView(this);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setSupportZoom(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                Uri u = req.getUrl();
                String host = u.getHost();
                if (host != null && host.equals(HOME_HOST)) return false;
                try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) {}
                return true;
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                runOnUiThread(() -> {
                    pendingPermRequest = request;
                    requestPermissions(new String[]{ Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO }, PERM_REQ);
                });
            }

            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (filePathCallback != null) { filePathCallback.onReceiveValue(null); }
                filePathCallback = cb;
                try {
                    startActivityForResult(params.createIntent(), FILE_REQ);
                } catch (Exception e) {
                    filePathCallback = null;
                    return false;
                }
                return true;
            }
        });

        root.addView(web, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);

        if (saved == null) web.loadUrl(START_URL);
        else web.restoreState(saved);

        checkForUpdate();
    }

    /* ---------------- AUTO UPDATER ---------------- */

    private void checkForUpdate() {
        new Thread(() -> {
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(RELEASES_API).openConnection();
                c.setRequestProperty("Accept", "application/vnd.github+json");
                c.setConnectTimeout(12000);
                c.setReadTimeout(12000);
                if (c.getResponseCode() != 200) return;
                StringBuilder sb = new StringBuilder();
                BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) sb.append(line);
                r.close();

                JSONObject json = new JSONObject(sb.toString());
                String tag = json.optString("tag_name", "").replaceFirst("^v", "");
                JSONArray assets = json.optJSONArray("assets");
                if (assets == null || assets.length() == 0) return;
                String url = null, name = "pulse.apk";
                for (int i = 0; i < assets.length(); i++) {
                    JSONObject a = assets.getJSONObject(i);
                    String an = a.optString("name", "");
                    if (an.endsWith(".apk")) { url = a.optString("browser_download_url"); name = an; break; }
                }
                if (url == null) return;
                if (isNewer(tag, BuildConfig.VERSION_NAME)) {
                    final String fUrl = url, fName = name, fTag = tag;
                    ui.post(() -> showUpdateDialog(fTag, fUrl, fName));
                }
            } catch (Exception ignored) {}
        }).start();
    }

    private boolean isNewer(String remote, String local) {
        try {
            String[] a = remote.split("\\.");
            String[] b = local.split("\\.");
            int n = Math.max(a.length, b.length);
            for (int i = 0; i < n; i++) {
                int x = i < a.length ? Integer.parseInt(a[i].replaceAll("[^0-9]", "")) : 0;
                int y = i < b.length ? Integer.parseInt(b[i].replaceAll("[^0-9]", "")) : 0;
                if (x > y) return true;
                if (x < y) return false;
            }
        } catch (Exception ignored) {}
        return false;
    }

    private void showUpdateDialog(String version, String url, String fileName) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (20 * getResources().getDisplayMetrics().density);
        box.setPadding(pad, pad, pad, pad);

        updateText = new TextView(this);
        updateText.setText("Naya version " + version + " available hai.\nUpdate karne ke liye OK dabao.");
        updateText.setTextSize(15f);
        box.addView(updateText);

        updateBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        updateBar.setMax(100);
        updateBar.setProgress(0);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = pad / 2;
        updateBar.setLayoutParams(lp);
        updateBar.setVisibility(android.view.View.GONE);
        box.addView(updateBar);

        updateDialog = new AlertDialog.Builder(this)
                .setTitle("Update available")
                .setView(box)
                .setPositiveButton("Update", (d, w) -> startDownload(url, fileName))
                .setNegativeButton("Baad me", (d, w) -> {})
                .setCancelable(true)
                .create();
        updateDialog.show();
    }

    private void startDownload(String url, String fileName) {
        try {
            DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
            req.setTitle("Pulse update");
            req.setDescription("Downloading " + fileName);
            req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE);
            req.setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName);
            req.setMimeType("application/vnd.android.package-archive");
            downloadId = dm.enqueue(req);

            if (updateBar != null) updateBar.setVisibility(android.view.View.VISIBLE);
            if (updateText != null) updateText.setText("Download ho raha hai… 0%");
            if (updateDialog != null && updateDialog.getButton(AlertDialog.BUTTON_POSITIVE) != null) {
                updateDialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
            }
            pollProgress();
        } catch (Exception e) {
            if (updateText != null) updateText.setText("Download fail: " + e.getMessage());
        }
    }

    private void pollProgress() {
        final DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
        ui.postDelayed(new Runnable() {
            @Override public void run() {
                if (downloadId < 0) return;
                DownloadManager.Query q = new DownloadManager.Query().setFilterById(downloadId);
                Cursor c = null;
                try {
                    c = dm.query(q);
                    if (c != null && c.moveToFirst()) {
                        int status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS));
                        long done = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR));
                        long total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES));
                        int pct = total > 0 ? (int) (done * 100 / total) : 0;
                        if (updateBar != null) updateBar.setProgress(pct);
                        if (updateText != null) updateText.setText("Download ho raha hai… " + pct + "%");

                        if (status == DownloadManager.STATUS_SUCCESSFUL) {
                            if (updateText != null) updateText.setText("Download complete — install karo");
                            installApk(dm.getUriForDownloadedFile(downloadId));
                            return;
                        }
                        if (status == DownloadManager.STATUS_FAILED) {
                            if (updateText != null) updateText.setText("Download fail ho gaya");
                            return;
                        }
                    }
                } catch (Exception ignored) {
                } finally {
                    if (c != null) c.close();
                }
                ui.postDelayed(this, 400);
            }
        }, 400);
    }

    private void installApk(Uri apkUri) {
        try {
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(apkUri, "application/vnd.android.package-archive");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
            if (updateDialog != null) updateDialog.dismiss();
        } catch (Exception e) {
            if (updateText != null) updateText.setText("Install fail — settings me 'install unknown apps' allow karo");
        }
    }

    /* ---------------- WEBVIEW PLUMBING ---------------- */

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (code == PERM_REQ) {
            boolean ok = true;
            for (int r : results) { if (r != PackageManager.PERMISSION_GRANTED) ok = false; }
            if (pendingPermRequest != null) {
                if (ok) pendingPermRequest.grant(pendingPermRequest.getResources());
                else pendingPermRequest.deny();
                pendingPermRequest = null;
            }
            return;
        }
        super.onRequestPermissionsResult(code, perms, results);
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req == FILE_REQ) {
            if (filePathCallback != null) {
                Uri[] out = null;
                if (res == Activity.RESULT_OK && data != null) {
                    if (data.getClipData() != null) {
                        int n = data.getClipData().getItemCount();
                        out = new Uri[n];
                        for (int i = 0; i < n; i++) out[i] = data.getClipData().getItemAt(i).getUri();
                    } else if (data.getData() != null) {
                        out = new Uri[]{ data.getData() };
                    }
                }
                filePathCallback.onReceiveValue(out);
                filePathCallback = null;
            }
            return;
        }
        super.onActivityResult(req, res, data);
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (code == KeyEvent.KEYCODE_BACK && web != null && web.canGoBack()) {
            web.goBack();
            return true;
        }
        return super.onKeyDown(code, e);
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (web != null) web.saveState(out);
    }
}
