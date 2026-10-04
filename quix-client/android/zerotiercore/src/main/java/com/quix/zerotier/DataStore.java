/*
 * This file is derived from ZerotierFix (https://github.com/kaaass/ZerotierFix),
 * licensed under the GPL-2.0 License. See LICENSE in this module for details.
 */
package com.quix.zerotier;

import android.content.Context;
import android.util.Log;

import com.zerotier.sdk.DataStoreGetListener;
import com.zerotier.sdk.DataStorePutListener;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;

/**
 * Zerotier 文件数据源。核心身份密钥等持久化数据保存在应用 filesDir 下
 */
public class DataStore implements DataStoreGetListener, DataStorePutListener {

    private static final String TAG = "DataStore";

    private final Context context;

    public DataStore(Context context) {
        this.context = context;
    }

    @Override
    public int onDataStorePut(String name, byte[] buffer, boolean secure) {
        Log.d(TAG, "Writing File: " + name + ", to: " + this.context.getFilesDir());
        try {
            if (name.contains("/")) {
                File dir = new File(this.context.getFilesDir(), name.substring(0, name.lastIndexOf('/')));
                if (!dir.exists()) {
                    dir.mkdirs();
                }
                FileOutputStream fileOutputStream = new FileOutputStream(new File(dir, name.substring(name.lastIndexOf('/') + 1)));
                fileOutputStream.write(buffer);
                fileOutputStream.flush();
                fileOutputStream.close();
                return 0;
            }
            FileOutputStream openFileOutput = this.context.openFileOutput(name, 0);
            openFileOutput.write(buffer);
            openFileOutput.flush();
            openFileOutput.close();
            return 0;
        } catch (FileNotFoundException e) {
            e.printStackTrace();
            return -1;
        } catch (IOException e2) {
            StringWriter stringWriter = new StringWriter();
            e2.printStackTrace(new PrintWriter(stringWriter));
            Log.e(TAG, stringWriter.toString());
            return -2;
        } catch (IllegalArgumentException e3) {
            StringWriter stringWriter2 = new StringWriter();
            e3.printStackTrace(new PrintWriter(stringWriter2));
            Log.e(TAG, stringWriter2.toString());
            return -3;
        }
    }

    @Override
    public int onDelete(String name) {
        boolean deleted;
        Log.d(TAG, "Deleting File: " + name);
        if (name.contains("/")) {
            File file = new File(this.context.getFilesDir(), name);
            if (!file.exists()) {
                deleted = true;
            } else {
                deleted = file.delete();
            }
        } else {
            deleted = this.context.deleteFile(name);
        }
        return !deleted ? 1 : 0;
    }

    @Override
    public long onDataStoreGet(String name, byte[] out_buffer) {
        Log.d(TAG, "Reading File: " + name);
        // 读入文件
        try {
            if (name.contains("/")) {
                File dir = new File(this.context.getFilesDir(), name.substring(0, name.lastIndexOf('/')));
                if (!dir.exists()) {
                    dir.mkdirs();
                }
                File file2 = new File(dir, name.substring(name.lastIndexOf('/') + 1));
                if (!file2.exists()) {
                    return 0;
                }
                FileInputStream fileInputStream = new FileInputStream(file2);
                int read = fileInputStream.read(out_buffer);
                fileInputStream.close();
                return read;
            }
            FileInputStream openFileInput = this.context.openFileInput(name);
            int read2 = openFileInput.read(out_buffer);
            openFileInput.close();
            return read2;
        } catch (FileNotFoundException unused) {
            return -1;
        } catch (IOException e) {
            Log.e(TAG, "", e);
            return -2;
        } catch (Exception e) {
            Log.e(TAG, "", e);
            return -3;
        }
    }
}
