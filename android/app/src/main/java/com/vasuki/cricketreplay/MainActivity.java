package com.aadhinitinytales.cricketreplay;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(android.os.Bundle savedInstanceState) {
        registerPlugin(FeasibilityPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
