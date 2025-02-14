/*-
 * Copyright (c) 2015-2018 elementary LLC. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Library General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

[DBus (name = "org.freedesktop.DBus.ObjectManager")]
public interface BluetoothIndicator.Services.DBusInterface : Object {
    public signal void interfaces_added (ObjectPath object_path, HashTable<string, HashTable<string, Variant>> param);
    public signal void interfaces_removed (ObjectPath object_path, string[] string_array);

    public abstract HashTable<ObjectPath, HashTable<string, HashTable<string, Variant>>> get_managed_objects () throws Error;
}

public class BluetoothIndicator.Services.ObjectManager : Object {
    public signal void global_state_changed (bool enabled, bool connected);
    public signal void device_added (BluetoothIndicator.Services.Device adapter);
    public signal void device_removed (BluetoothIndicator.Services.Device adapter);

    public bool has_object { get; private set; default = false; }
    public bool retrieve_finished { get; private set; default = false; }
    private Settings settings;
    private BluetoothIndicator.Services.DBusInterface object_interface;
    private Gee.HashMap<string, BluetoothIndicator.Services.Adapter> adapters;
    private Gee.HashMap<string, BluetoothIndicator.Services.Device> devices;

    public bool is_powered {get; private set; default = false; }
    public bool is_connected {get; private set; default = false; }

    construct {
        adapters = new Gee.HashMap<string, BluetoothIndicator.Services.Adapter> (null, null);
        devices = new Gee.HashMap<string, BluetoothIndicator.Services.Device> (null, null);

        settings = new Settings ("io.elementary.desktop.wingpanel.bluetooth");

        Bus.get_proxy.begin<BluetoothIndicator.Services.DBusInterface> (BusType.SYSTEM, "org.bluez", "/", DBusProxyFlags.NONE, null, (obj, res) => {
            try {
                object_interface = Bus.get_proxy.end (res);
                object_interface.get_managed_objects ().foreach (add_path);
                object_interface.interfaces_added.connect (add_path);
                object_interface.interfaces_removed.connect (remove_path);
                check_global_state ();
                retrieve_finished = true;
            } catch (Error e) {
                critical (e.message);
            }
        });
    }

    [CCode (instance_pos = -1)]
    private void add_path (ObjectPath path, HashTable<string, HashTable<string, Variant>> param) {
        if ("org.bluez.Adapter1" in param) {
            try {
                BluetoothIndicator.Services.Adapter adapter = Bus.get_proxy_sync (BusType.SYSTEM, "org.bluez", path, DBusProxyFlags.GET_INVALIDATED_PROPERTIES);
                lock (adapters) {
                    adapters.set (path, adapter);
                }

                has_object = true;

                (adapter as DBusProxy).g_properties_changed.connect ((changed, invalid) => {
                    var powered = changed.lookup_value ("Powered", new VariantType ("b"));
                    if (powered != null) {
                        check_global_state ();
                    }
                });
            } catch (Error e) {
                debug ("Connecting to bluetooth adapter failed: %s", e.message);
            }
        } else if ("org.bluez.Device1" in param) {
            try {
                BluetoothIndicator.Services.Device device = Bus.get_proxy_sync (BusType.SYSTEM, "org.bluez", path, DBusProxyFlags.GET_INVALIDATED_PROPERTIES);
                if (device.paired) {
                    add_device (device, path);
                }

                (device as DBusProxy).g_properties_changed.connect ((changed, invalid) => {
                    var connected = changed.lookup_value ("Connected", new VariantType ("b"));
                    if (connected != null) {
                        check_global_state ();
                    }

                    var paired = changed.lookup_value ("Paired", new VariantType ("b"));
                    if (paired != null) {
                        if (device.paired) {
                            add_device (device, path);
                        } else {
                            lock (devices) {
                                devices.unset (path);
                            }

                            device_removed (device);
                        }
                    }
                });
            } catch (Error e) {
                debug ("Connecting to bluetooth device failed: %s", e.message);
            }
        }
    }

    [CCode (instance_pos = -1)]
    private void remove_path (ObjectPath path) {
        lock (adapters) {
            var adapter = adapters.get (path);
            if (adapter != null) {
                adapters.unset (path);
                has_object = !adapters.is_empty;

                return;
            }
        }

        lock (devices) {
            var device = devices.get (path);
            if (device != null) {
                devices.unset (path);
                device_removed (device);
            }
        }
    }

    private void add_device (BluetoothIndicator.Services.Device device, string path) {
        lock (devices) {
            if (!devices.has_key (path)) {
                devices[path] = device;
                device_added (device);
            }
        }
    }

    public Gee.Collection<BluetoothIndicator.Services.Device> get_devices () {
        lock (devices) {
            return devices.values;
        }
    }

    public void check_global_state () {
        /* As this is called within a signal handler, it should be in a Idle loop  else
         * races occur */
        Idle.add (() => {
            var powered = get_global_state ();
            var connected = get_connected ();

            /* Only signal if actually changed */
            if (powered != is_powered || connected != is_connected) {
                is_powered = powered;
                is_connected = connected;
                global_state_changed (is_powered, is_connected);
            }
            return false;
        });
    }

    public bool get_connected () {
        lock (devices) {
            foreach (var device in devices.values) {
                if (device.connected) {
                    return true;
                }
            }
        }

        return false;
    }

    public bool get_global_state () {
        lock (adapters) {
            foreach (var adapter in adapters.values) {
                if (adapter.powered) {
                    return true;
                }
            }
        }

        return false;
    }

    public async void set_global_state (bool state) {
        /* `is_powered` and `connected` properties will be set by the check_global state () callback when adapter or device
         * properties change.  Do not set now so that global_state_changed signal will be emitted. */

        lock (adapters) {
            foreach (var adapter in adapters.values) {
                adapter.powered = state;
            }
        }

        if (state == false) {
            lock (devices) {
                foreach (var device in devices.values) {
                    if (device.connected) {
                        try {
                            yield device.disconnect ();
                        } catch (Error e) {
                            critical (e.message);
                        }
                    }
                }
            }
        }

        settings.set_boolean ("bluetooth-enabled", state);
    }

    public async void set_last_state () {
        bool last_state = settings.get_boolean ("bluetooth-enabled");

        if (get_global_state () != last_state) {
            yield set_global_state (last_state);
        }

        check_global_state ();
    }

    public static bool compare_devices (Device device, Device other) {
        return device.modalias == other.modalias;
    }
}
