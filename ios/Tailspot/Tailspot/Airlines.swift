//
//  Airlines.swift
//  Tailspot
//
//  ICAO airline-designator → airline-name lookup, used to resolve a catch's
//  operator from its CALLSIGN when the position/metadata feed didn't provide
//  one (OpenSky's per-airframe metadata frequently has no operator).
//
//  An airline callsign is a 3-letter ICAO designator followed by a flight
//  number ("SWA4244" → Southwest). A general-aviation plane flies under its
//  registration ("N172SP"), which has digits in the first few characters and
//  so resolves to no airline — correctly, since it has no airline operator.
//
//  Not exhaustive (there are ~1,400 ICAO designators); this is the common set
//  a spotter actually sees. Add as gaps surface.
//

import Foundation

nonisolated enum Airlines {

    /// ICAO 3-letter designator → display name.
    static let byICAO: [String: String] = [
        // US majors / low-cost
        "UAL": "United Airlines", "AAL": "American Airlines", "DAL": "Delta Air Lines",
        "SWA": "Southwest Airlines", "ASA": "Alaska Airlines", "JBU": "JetBlue Airways",
        "NKS": "Spirit Airlines", "FFT": "Frontier Airlines", "HAL": "Hawaiian Airlines",
        "SCX": "Sun Country Airlines", "AAY": "Allegiant Air", "VXP": "Avelo Airlines",
        "MXY": "Breeze Airways",
        // US regionals
        "SKW": "SkyWest Airlines", "RPA": "Republic Airways", "ENY": "Envoy Air",
        "EDV": "Endeavor Air", "JIA": "PSA Airlines", "AWI": "Air Wisconsin",
        "GJS": "GoJet Airlines", "ASH": "Mesa Airlines", "QXE": "Horizon Air",
        "CPZ": "Compass Airlines", "ASQ": "ExpressJet",
        // US cargo
        "FDX": "FedEx Express", "UPS": "UPS Airlines", "GTI": "Atlas Air",
        "ABX": "ABX Air", "GEC": "Lufthansa Cargo", "PAC": "Polar Air Cargo",
        "CKS": "Kalitta Air", "CLX": "Cargolux", "ATN": "Air Transport International",
        "FDX2": "FedEx Express",
        // Canada
        "ACA": "Air Canada", "WJA": "WestJet", "JZA": "Jazz Aviation",
        "ROU": "Air Canada Rouge", "POE": "Porter Airlines", "TSC": "Air Transat",
        // Latin America
        "AMX": "Aeroméxico", "VOI": "Volaris", "CMP": "Copa Airlines",
        "AVA": "Avianca", "GLO": "GOL", "AZU": "Azul", "ARG": "Aerolíneas Argentinas",
        "LAN": "LATAM", "TAM": "LATAM Brasil", "ARE": "Aeroméxico Connect",
        // Europe
        "BAW": "British Airways", "DLH": "Lufthansa", "AFR": "Air France", "KLM": "KLM",
        "IBE": "Iberia", "EZY": "easyJet", "RYR": "Ryanair", "VLG": "Vueling",
        "SAS": "Scandinavian Airlines", "SWR": "Swiss", "AUA": "Austrian Airlines",
        "TAP": "TAP Air Portugal", "FIN": "Finnair", "VIR": "Virgin Atlantic",
        "EIN": "Aer Lingus", "NAX": "Norwegian", "BEL": "Brussels Airlines",
        "LOT": "LOT Polish Airlines", "THY": "Turkish Airlines", "AEE": "Aegean Airlines",
        "ITY": "ITA Airways", "ICE": "Icelandair", "WZZ": "Wizz Air",
        // Middle East
        "UAE": "Emirates", "QTR": "Qatar Airways", "ETD": "Etihad Airways",
        "SVA": "Saudia", "ELY": "El Al", "MEA": "Middle East Airlines",
        // Asia / Pacific
        "ANA": "All Nippon Airways", "JAL": "Japan Airlines", "SIA": "Singapore Airlines",
        "CPA": "Cathay Pacific", "KAL": "Korean Air", "AAR": "Asiana Airlines",
        "EVA": "EVA Air", "CAL": "China Airlines", "CCA": "Air China",
        "CES": "China Eastern", "CSN": "China Southern", "THA": "Thai Airways",
        "MAS": "Malaysia Airlines", "GIA": "Garuda Indonesia", "PAL": "Philippine Airlines",
        "HVN": "Vietnam Airlines", "VJC": "VietJet Air", "QFA": "Qantas",
        "ANZ": "Air New Zealand", "VOZ": "Virgin Australia", "JST": "Jetstar",
        "AIC": "Air India", "IGO": "IndiGo",
    ]

    /// True when the callsign is an airline flight number (3-letter designator
    /// + a digit), as opposed to a GA registration ("N172SP").
    static func isAirlineFormat(_ callsign: String?) -> Bool {
        guard let cs = callsign?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              cs.count >= 4 else { return false }
        let fourth = cs[cs.index(cs.startIndex, offsetBy: 3)]
        return cs.prefix(3).allSatisfy { $0.isLetter } && fourth.isNumber
    }

    /// Airline name for a callsign, or nil if it isn't an airline callsign /
    /// the designator isn't in the table.
    static func name(forCallsign callsign: String?) -> String? {
        guard isAirlineFormat(callsign),
              let cs = callsign?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        else { return nil }
        return byICAO[String(cs.prefix(3))]
    }

    /// What to show for "operator": the recorded operator, else the
    /// callsign-derived airline, else "Private" for GA-format callsigns,
    /// else "Operator unknown" for an airline we don't have in the table.
    static func operatorLabel(operatorName: String?, callsign: String?) -> String {
        if let op = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !op.isEmpty {
            return op
        }
        if let airline = name(forCallsign: callsign) { return airline }
        return isAirlineFormat(callsign) ? "Operator unknown" : "Private"
    }
}
