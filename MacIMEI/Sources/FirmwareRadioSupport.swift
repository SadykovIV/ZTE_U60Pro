import Foundation

/// Temporary, read-only DIAG/QMI probes. No installed agent or firmware write profile is needed.
enum FirmwareRadioSupport {
    static let probes: [(name: String, argument: String, header: String)] = [
        ("zte-support-nv", "--inspect-nv550", "SUPPORT_NV_V1"),
        ("zte-support-config", "--inspect-config", "SUPPORT_CONFIG_V1"),
        ("zte-support-qmi", "--inspect-current-card", "")
    ]
    static let hashes: [String: String] = [
        "zte-support-nv": "d41b1d537a0f690cc8dc954bd63bb2f41179e862a76818c650ee0b66346d3c76",
        "zte-support-config": "61cfce1263c9c882eccf2303b93f83fa3f0e96919ed7da60e690df5a148fa262",
        "zte-support-qmi": "8ae8a370596c1369b6c03c9fe5c048dccd83e8dda6b0947b4204b407934d2d0d",
    ]
    private static let linePatterns = [
        "^EFS_CLOSE fd=-?[0-9]{1,10} verified=-?[0-9]{1,10}$",
        "^EFS_EARLY_RELEASE -?[0-9]{1,10}$",
        "^EFS_OPEN fd=-?[0-9]{1,10} errno=-?[0-9]{1,10} flags=0 mode=0$",
        "^EFS_OPEN_NO_VALID_DESCRIPTOR$",
        "^EFS_OPEN_OWNERSHIP_UNCERTAIN$",
        "^EFS_OWNER ret=-?[0-9]{1,10} pid=-?[0-9]{1,10} self=-?[0-9]{1,10}$",
        "^EFS_READ fd=-?[0-9]{1,10} offset=-?[0-9]{1,10} requested=-?[0-9]{1,10} returned=-?[0-9]{1,10} errno=-?[0-9]{1,10} exact=-?[0-9]{1,10}$",
        "^EFS_RELEASE ret=-?[0-9]{1,10} owner=-?[0-9]{1,10} local_mode=-?[0-9]{1,10}$",
        "^EFS_RELEASE_OWNERSHIP_UNCERTAIN$",
        "^EFS_REQUEST label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) send=-?[0-9]{1,10} length=-?[0-9]{1,10} diag_error=-?[0-9]{1,10} crc_valid=-?[0-9]{1,10}$",
        "^EFS_RESULT outcome=-?[0-9]{1,10} bytes=-?[0-9]{1,10} file_closed=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} signal=-?[0-9]{1,10} crc_verified_frames=-?[0-9]{1,10} bad_crc_frames=-?[0-9]{1,10}$",
        "^EFS_SESSION_OPEN -?[0-9]{1,10}$",
        "^EFS_STAT label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) errno=-?[0-9]{1,10} mode=0x[0-9a-f]{1,8} size=-?[0-9]{1,10} nlink=-?[0-9]{1,10}$",
        "^PAIR_EARLY_RELEASE -?[0-9]{1,10}$",
        "^PAIR_FRAME_BAD_CRC$",
        "^PAIR_OPEN_OWNERSHIP_UNCERTAIN$",
        "^PAIR_OWNER ret=-?[0-9]{1,10} pid=-?[0-9]{1,10} self=-?[0-9]{1,10}$",
        "^PAIR_RELEASE ret=-?[0-9]{1,10} owner=-?[0-9]{1,10} local_mode=-?[0-9]{1,10}$",
        "^PAIR_RELEASE_OWNERSHIP_UNCERTAIN$",
        "^PAIR_REQUEST label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) send=-?[0-9]{1,10} length=-?[0-9]{1,10} status=-?[0-9]{1,10} diag_error=-?[0-9]{1,10} verified=-?[0-9]{1,10}$",
        "^PAIR_RESULT outcome=-?[0-9]{1,10} write_attempts=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} signal=-?[0-9]{1,10}$",
        "^PAIR_SESSION_OPEN -?[0-9]{1,10}$",
        "^PAIR_SNAPSHOT readable=-?[0-9]{1,10} legacy_alias=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_FLAG102 offset=-?[0-9]{1,10} length=-?[0-9]{1,10} value=-?[0-9]{1,10} b31_layout=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_FORMAT bytes=-?[0-9]{1,10} magic_known=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_HEADER records=-?[0-9]{1,10} declared_size=-?[0-9]{1,10} length_valid=-?[0-9]{1,10} trailer_known=-?[0-9]{1,10} crc_valid=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_LOAD library=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_RECORD index=-?[0-9]{1,10} id=-?[0-9]{1,10} offset=-?[0-9]{1,10} length=-?[0-9]{1,10} reserved_zero=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_RESPONSE label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) unmatched_frames=-?[0-9]{1,10} last_unmatched_length=-?[0-9]{1,10} last_unmatched_opcode=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_RESULT outcome=-?[0-9]{1,10} file_closed=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} writes=0$",
        "^SUPPORT_CONFIG_STRUCTURE valid=-?[0-9]{1,10} reason=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) consumed=-?[0-9]{1,10} flag102_count=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_STRUCTURE valid=0 reason=duplicate_id index=-?[0-9]{1,10} id=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_STRUCTURE valid=0 reason=invalid_header$",
        "^SUPPORT_CONFIG_STRUCTURE valid=0 reason=invalid_record index=-?[0-9]{1,10} offset=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_STRUCTURE valid=0 reason=truncated_record index=-?[0-9]{1,10} offset=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_STRUCTURE valid=0 reason=unknown_header$",
        "^SUPPORT_CONFIG_SYMBOLS init=-?[0-9]{1,10} deinit=-?[0-9]{1,10} callback=-?[0-9]{1,10} send=-?[0-9]{1,10} ioctl=-?[0-9]{1,10} fd=-?[0-9]{1,10} mode=-?[0-9]{1,10}$",
        "^SUPPORT_CONFIG_V1$",
        "^SUPPORT_NV_LOAD library=-?[0-9]{1,10}$",
        "^SUPPORT_NV_RECORD index=-?[0-9]{1,10} readable=-?[0-9]{1,10} encoding_valid=-?[0-9]{1,10}$",
        "^SUPPORT_NV_RESPONSE label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) unmatched_frames=-?[0-9]{1,10} last_unmatched_length=-?[0-9]{1,10} last_unmatched_opcode=-?[0-9]{1,10}$",
        "^SUPPORT_NV_RESULT outcome=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} writes=0$",
        "^SUPPORT_NV_STRUCTURE legacy_readable=-?[0-9]{1,10} legacy_alias=-?[0-9]{1,10} crc_verified_frames=-?[0-9]{1,10} bad_crc_frames=-?[0-9]{1,10}$",
        "^SUPPORT_NV_SYMBOLS init=-?[0-9]{1,10} deinit=-?[0-9]{1,10} callback=-?[0-9]{1,10} send=-?[0-9]{1,10} ioctl=-?[0-9]{1,10} fd=-?[0-9]{1,10} mode=-?[0-9]{1,10}$",
        "^SUPPORT_NV_V1$"
    ]
    private static func project(_ value: Any, key: String) -> Any? {
        if ["observations", "operating_mode", "card_status", "slot_status", "root"].contains(key), let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                if let safe = project(pair.value, key: pair.key) { result[pair.key] = safe }
            }
        }
        if ["cards", "slots", "applications"].contains(key), let array = value as? [[String: Any]], array.count <= 32 {
            return array.compactMap { project($0, key: "root") }
        }
        if ["primary_gw_index", "primary_1x_index", "secondary_gw_index", "secondary_1x_index", "schema", "qmi_result", "qmi_error", "mode", "logical_index", "state", "error", "type", "aid_length", "physical_index", "card_state", "slot_state", "logical_slot", "iccid_length", "protocol", "application_count", "atr_length", "eid_length"].contains(key), let number = value as? NSNumber,
           String(describing: number).range(of: #"^[0-9]{1,10}$"#, options: .regularExpression) != nil,
           number.uint64Value <= UInt32.max { return number }
        if ["identifiers_exported", "radio_reset", "slot_switch", "profile_mutation", "apdu_performed", "provisioning_proven", "is_euicc"].contains(key), let flag = value as? Bool { return flag }
        if key == "status", let text = value as? String, ["observed", "not_assessed"].contains(text) { return text }
        if key == "reason", let text = value as? String, ["missing_field", "duplicate_field", "length_overflow", "truncated_field", "trailing_bytes", "card_count", "application_count", "slot_count", "slot_enum", "slot_array_count", "euicc_enum", "result_length", "mode_length", "operation_not_readonly", "service_unavailable", "request_failed"].contains(text) { return text }
        return nil
    }
    static func output(_ result: CommandResult, header: String) -> String {
        guard result.stdout.count <= 131072, let raw = String(data: result.stdout, encoding: .utf8) else { return "status=invalid_output\n" }
        if header.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                  object["schema"] as? Int == 1, object["identifiers_exported"] as? Bool == false,
                  object["radio_reset"] as? Bool == false, object["slot_switch"] as? Bool == false,
                  object["profile_mutation"] as? Bool == false, object["apdu_performed"] as? Bool == false else { return "status=invalid_output\n" }
            guard let safe = project(object, key: "root"), let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "status=invalid_output\n" }
            return text + "\n"
        }
        guard raw.split(separator: "\n").contains(Substring(header)) else { return "status=missing_summary\nexit_code=\(result.status)\n" }
        let lines = raw.split(separator: "\n").filter { line in
            line.utf8.allSatisfy { $0 >= 32 && $0 <= 126 } &&
            linePatterns.contains { String(line).range(of: $0, options: .regularExpression) != nil }
        }
        return lines.joined(separator: "\n") + "\nexit_code=\(result.status)\n"
    }
    static func collect(resources: URL, remote: RemoteTransport, root: Bool,
                        cancelled: @escaping @Sendable () -> Bool) throws -> [String: Data] {
        if !root { return ["native-status.txt": Data("status=not_assessed reason=root_required\n".utf8)] }
        let folder = resources.appendingPathComponent("FirmwareSupport")
        let manifest = try readJSON([String: String].self, folder.appendingPathComponent("SHA256.json"))
        var payloads = [String: Data]()
        for probe in probes {
            let bytes = try DeviceBackups.smallFile(folder.appendingPathComponent(probe.name), maximum: 8 * 1024 * 1024, publicResource: true)
            try require(hashes[probe.name] == digest(bytes) && manifest[probe.name] == digest(bytes), "Повреждён встроенный сборщик данных для адаптации")
            payloads[probe.name] = bytes
        }
        let stage = "/tmp/zte-support-" + UUID().uuidString.lowercased()
        let created = try remote.run("umask 077; mkdir " + shellQuote(stage), input: nil, timeout: 15)
        try require(created.status == 0, "Не удалось создать временный каталог исследования")
        defer { _ = try? remote.run("rm -f " + probes.map { shellQuote(stage + "/" + $0.name) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), input: nil, timeout: 15) }
        var results = [String: Data]()
        for probe in probes {
            try require(!cancelled(), "Сбор данных для адаптации отменён")
            let path = stage + "/" + probe.name, bytes = payloads[probe.name]!, expected = hashes[probe.name]!
            let uploaded = try remote.run("cat > " + shellQuote(path) + " && chmod 700 " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: bytes, timeout: 30)
            try require(uploaded.status == 0 && String(decoding: uploaded.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init) == [expected, path], "При передаче повреждён диагностический помощник")
            let command = "test \"$(sha256sum " + shellQuote(path) + " | cut -d ' ' -f1)\" = " + shellQuote(expected) + " && " + shellQuote(path) + " " + probe.argument
            do {
                let reply = try remote.run(command, input: nil, timeout: 150)
                results[probe.name + ".txt"] = Data(output(reply, header: probe.header).utf8)
            } catch {
                try require(!cancelled(), "Сбор данных для адаптации отменён")
                results[probe.name + ".txt"] = Data("status=not_assessed reason=transport_or_probe_failure\n".utf8)
            }
        }
        return results
    }
}
