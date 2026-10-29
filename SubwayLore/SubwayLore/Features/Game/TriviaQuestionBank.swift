import Foundation

struct TriviaQuestion: Equatable, Sendable {
    let id: Int
    let category: String
    let prompt: String
    let choices: [String]
    // The bank stores the answer first. Each match randomizes its displayed A–D order.
    var correctOption: Int { 0 }
}

enum TriviaQuestionBank {
    static let version = 1
    static let questions: [TriviaQuestion] = rows.enumerated().map { index, row in
        TriviaQuestion(id: index + 1, category: category(for: index + 1), prompt: row[0], choices: Array(row.dropFirst()))
    }
    static func question(_ id: Int) -> TriviaQuestion? { questions.first { $0.id == id } }
    private static func category(for id: Int) -> String {
        switch id {
        case 1...20: "Subway Basics"
        case 21...45: "Lines, Colors & Routes"
        case 46...65: "Where in New York?"
        case 66...90: "Subway History"
        default: "Culture & Fun Facts"
        }
    }

    // Adapted from the user's 100-question bank. Open-ended and binary prompts become single-answer MCQs.
    private static let rows: [[String]] = [
        ["How many NYC boroughs are served by the New York City Subway?", "4", "2", "3", "5"],
        ["Which borough has no NYC Subway service?", "Staten Island", "Queens", "Brooklyn", "The Bronx"],
        ["Which organization operates the NYC Subway?", "The MTA", "Amtrak", "NJ Transit", "The Port Authority"],
        ["What does MTA stand for?", "Metropolitan Transportation Authority", "Manhattan Transit Association", "Municipal Train Administration", "Metro Travel Agency"],
        ["How many hours a day does the NYC Subway normally operate?", "24", "12", "18", "20"],
        ["What is the main difference between local and express trains?", "Express trains skip some stations", "Local trains never stop", "Express trains are always above ground", "Local trains require reservations"],
        ["In Manhattan, uptown generally means traveling in which direction?", "North", "South", "East", "West"],
        ["In Manhattan, downtown generally means traveling in which direction?", "South", "North", "East", "West"],
        ["What supplies electrical power to NYC subway trains?", "The third rail", "Solar panels", "Diesel engines", "Overhead trolley wires"],
        ["What are subway train wheels primarily made of?", "Steel", "Rubber", "Plastic", "Wood"],
        ["What is the person who drives a subway train called?", "Train operator", "Dispatcher", "Station agent", "Track inspector"],
        ["Who usually controls subway doors and makes announcements?", "The conductor", "The station agent", "The fare inspector", "The track worker"],
        ["Complete: ‘Stand clear of the _____, please.’", "Closing doors", "Yellow benches", "Moving stairs", "Front windows"],
        ["Which rider nickname comes from the straps passengers once held?", "Straphangers", "Trackwalkers", "Railrunners", "Tunnel riders"],
        ["What nickname is commonly used for an elevated subway line?", "The El", "The Loop", "The Tube", "The Link"],
        ["What does an S route usually represent?", "A shuttle", "A sleeper train", "A seasonal route", "A sightseeing train"],
        ["What is the colored circle containing a route letter or number called?", "A route bullet", "A platform seal", "A fare marker", "A station badge"],
        ["What does terminal mean in subway terminology?", "The end of a route", "A fare machine", "An express-only stop", "A train storage car"],
        ["What color is the safety strip commonly found along platform edges?", "Yellow", "Blue", "Purple", "Green"],
        ["Which description of the NYC Subway is accurate?", "Large parts run outdoors or above street level", "Every track is underground", "Only shuttle routes run outdoors", "No subway train crosses a bridge"],
        ["What color represents the 1, 2 and 3 trains?", "Red", "Blue", "Green", "Orange"],
        ["What color represents the 4, 5 and 6 trains?", "Green", "Red", "Yellow", "Purple"],
        ["What color represents the A, C and E trains?", "Blue", "Orange", "Brown", "Gray"],
        ["What color represents the B, D, F and M trains?", "Orange", "Blue", "Red", "Yellow"],
        ["What color represents the N, Q, R and W trains?", "Yellow", "Green", "Purple", "Brown"],
        ["What color represents the 7 train?", "Purple", "Orange", "Gray", "Red"],
        ["What color represents the G train?", "Light green", "Dark blue", "Brown", "Yellow"],
        ["What color represents the L train?", "Gray", "Purple", "Red", "Green"],
        ["What color represents the J and Z trains?", "Brown", "Blue", "Orange", "Yellow"],
        ["Which lettered, non-shuttle route is famous for never entering Manhattan?", "The G", "The L", "The F", "The J"],
        ["The 7 train primarily connects Manhattan with which borough?", "Queens", "Brooklyn", "The Bronx", "Staten Island"],
        ["Which train serves Roosevelt Island on nights and weekends under the regular service pattern?", "The F", "The G", "The L", "The 7"],
        ["Which subway line is commonly used to reach the Rockaways?", "The A", "The G", "The 1", "The 6"],
        ["Which subway line serves Citi Field?", "The 7", "The 2", "The L", "The Q"],
        ["What subway station serves Citi Field?", "Mets–Willets Point", "Queensboro Plaza", "Astoria–Ditmars Blvd", "Jamaica Center"],
        ["Which of these trains terminates at Coney Island–Stillwell Avenue?", "The D", "The 1", "The 6", "The L"],
        ["Which shuttle connects Times Square and Grand Central?", "The 42 St Shuttle", "The Franklin Avenue Shuttle", "The Rockaway Park Shuttle", "The JFK AirTrain"],
        ["Which train serves 34 St–Hudson Yards?", "The 7", "The 3", "The A", "The G"],
        ["Which train runs along the first completed section of the Second Avenue Subway?", "The Q", "The R", "The 6", "The E"],
        ["Which numbered train serves WTC Cortlandt?", "The 1", "The 2", "The 4", "The 7"],
        ["What subway station serves Yankee Stadium?", "161 St–Yankee Stadium", "149 St–Grand Concourse", "125 St", "167 St"],
        ["Which station is named for the American Museum of Natural History?", "81 St–Museum of Natural History", "86 St–Lexington Avenue", "72 St–Second Avenue", "66 St–Lincoln Center"],
        ["Which major Brooklyn station has Barclays Center in its name?", "Atlantic Av–Barclays Center", "Jay St–MetroTech", "Borough Hall", "DeKalb Av"],
        ["Which station shares its name with the nearby Staten Island Ferry terminal?", "South Ferry", "Fulton St", "Bowling Green", "Rector St"],
        ["Which station is named after Manhattan’s major bus terminal?", "42 St–Port Authority Bus Terminal", "34 St–Penn Station", "59 St–Columbus Circle", "Grand Central–42 St"],
        ["Which borough is Coney Island in?", "Brooklyn", "Queens", "Manhattan", "The Bronx"],
        ["Which borough is Astoria in?", "Queens", "Brooklyn", "Manhattan", "Staten Island"],
        ["Which borough is Harlem in?", "Manhattan", "Queens", "The Bronx", "Brooklyn"],
        ["Which borough is Flushing in?", "Queens", "Manhattan", "Brooklyn", "The Bronx"],
        ["Which borough is Yankee Stadium in?", "The Bronx", "Brooklyn", "Queens", "Manhattan"],
        ["Which borough is Broadway Junction in?", "Brooklyn", "Queens", "Manhattan", "The Bronx"],
        ["Which borough contains the Rockaway Peninsula?", "Queens", "Brooklyn", "Staten Island", "The Bronx"],
        ["Roosevelt Island sits in which river?", "The East River", "The Hudson River", "The Harlem River", "The Bronx River"],
        ["Which famous park is right next to 59 St–Columbus Circle?", "Central Park", "Prospect Park", "Bryant Park", "Washington Square Park"],
        ["Grand Central’s main subway station is at which numbered street?", "42nd Street", "34th Street", "59th Street", "14th Street"],
        ["Times Square’s main subway complex is centered around which street?", "42nd Street", "23rd Street", "72nd Street", "125th Street"],
        ["Which NYC airport can subway riders reach by transferring to the AirTrain?", "JFK Airport", "LaGuardia Airport", "Teterboro Airport", "Floyd Bennett Field"],
        ["Which of these trains connects to the JFK AirTrain?", "The E", "The B", "The D", "The L"],
        ["Penn Station’s subway stops are centered around which street?", "34th Street", "14th Street", "42nd Street", "59th Street"],
        ["Union Square’s subway complex is centered around which street?", "14th Street", "23rd Street", "34th Street", "86th Street"],
        ["Which Lower Manhattan station includes both a famous bridge and City Hall in its name?", "Brooklyn Bridge–City Hall", "Manhattan Bridge–Canal", "Williamsburg Bridge–Fulton", "Queensboro Bridge–Broad"],
        ["Which subway station takes its name from NYC’s oldest public park?", "Bowling Green", "Union Square", "Prospect Park", "Central Park North"],
        ["Which park gives the northern terminal of the 1 train its name?", "Van Cortlandt Park", "Pelham Bay Park", "Fort Tryon Park", "Inwood Hill Park"],
        ["Which borough is Prospect Park in?", "Brooklyn", "Queens", "Manhattan", "The Bronx"],
        ["Which borough is Queensboro Plaza in?", "Queens", "Brooklyn", "Manhattan", "The Bronx"],
        ["What year did New York City’s subway open?", "1904", "1883", "1920", "1932"],
        ["On what date did the original subway open to the public?", "October 27, 1904", "January 1, 1900", "July 4, 1910", "April 30, 1939"],
        ["How many stations did the original subway have?", "28", "12", "42", "100"],
        ["Approximately how long was the original subway route?", "9 miles", "2 miles", "25 miles", "50 miles"],
        ["From which station did New York’s first subway ride depart?", "City Hall", "Times Square", "Grand Central", "South Ferry"],
        ["How much did a subway ride cost when the system opened in 1904?", "5 cents", "1 cent", "10 cents", "25 cents"],
        ["In what year were NYC’s three major subway systems unified under city control?", "1940", "1904", "1929", "1968"],
        ["What were the three historic subway systems known as?", "IRT, BMT and IND", "MTA, PATH and LIRR", "NJT, IND and MARC", "BRT, LIRR and PATH"],
        ["What did IRT stand for?", "Interborough Rapid Transit", "International Rail Transport", "Island Railway Terminal", "Independent Rapid Trains"],
        ["What did BMT stand for?", "Brooklyn-Manhattan Transit", "Bronx Municipal Trains", "Brooklyn Metro Tunnels", "Broadway Metropolitan Transit"],
        ["What did IND stand for?", "Independent Subway", "Interborough Northern Division", "International New York District", "Island Network Department"],
        ["Today’s numbered subway routes mostly trace their history to which system?", "IRT", "BMT", "IND", "PATH"],
        ["Today’s lettered routes mostly trace their history to which two systems?", "BMT and IND", "IRT and PATH", "LIRR and IRT", "PATH and NJ Transit"],
        ["What is the original City Hall subway station’s status?", "Closed to regular passengers", "An active express terminal", "A regular 7 train stop", "A Metro-North terminal"],
        ["Which train passes through old City Hall station while turning around?", "The 6", "The 1", "The 7", "The L"],
        ["Which abandoned station is famous for chandeliers, skylights and curved tiled ceilings?", "City Hall", "South Ferry", "Myrtle Avenue", "18th Street"],
        ["Before the MetroCard, what small object was commonly used to enter the subway?", "A subway token", "A boarding key", "A paper bracelet", "A luggage tag"],
        ["In what decade was the MetroCard introduced?", "The 1990s", "The 1960s", "The 1970s", "The 2010s"],
        ["What does OMNY stand for?", "One Metro New York", "Only Manhattan New York", "Official Metropolitan New York", "One Municipal Network Year"],
        ["What nickname was given to famous red-painted subway cars?", "Redbirds", "Cardinals", "Redliners", "Fireflies"],
        ["What major 2012 storm severely flooded the subway system?", "Hurricane Sandy / Superstorm Sandy", "Hurricane Katrina", "Hurricane Andrew", "Hurricane Ida"],
        ["Which subway line was extended to Hudson Yards in 2015?", "The 7", "The L", "The A", "The G"],
        ["What long-awaited subway project opened its first phase in 2017?", "The Second Avenue Subway", "The 7 extension", "The Archer Avenue lines", "The AirTrain JFK"],
        ["Which three new stations opened with the first phase of the Second Avenue Subway?", "72 St, 86 St and 96 St", "14 St, 23 St and 34 St", "103 St, 110 St and 116 St", "57 St, 59 St and 63 St"],
        ["What former subway station is home to the New York Transit Museum?", "Court Street", "City Hall", "Worth Street", "Chambers Street"],
        ["Which subway line appears in ‘Take the A Train’?", "The A", "The C", "The E", "The G"],
        ["Who composed ‘Take the A Train’?", "Billy Strayhorn", "Louis Armstrong", "George Gershwin", "Charlie Parker"],
        ["Which teams play in New York’s modern Subway Series?", "The Yankees and Mets", "The Knicks and Nets", "The Giants and Jets", "The Rangers and Islanders"],
        ["What animal became an internet celebrity dragging pizza down subway stairs?", "A rat", "A pigeon", "A squirrel", "A raccoon"],
        ["On the subway map, what does a white station circle generally indicate?", "An express stop", "A closed station", "A local-only stop", "A bus transfer only"],
        ["On the subway map, what does a black station dot generally indicate?", "A local-only stop", "An express-only stop", "A closed station", "An airport terminal"],
        ["On routes such as the 6 and 7, what does a diamond-shaped route symbol indicate?", "Express service", "Shuttle service", "A train out of service", "An airport connection"],
        ["Why do conductors point at a black-and-white board before opening the doors?", "To confirm the train is correctly positioned", "To request an express track", "To signal a fare change", "To ask passengers to board"],
        ["In subway-car names such as R160 or R211, what does R stand for?", "Rolling stock", "Rapid express", "Route", "Railway station"],
        ["Which 1 train station reopened in 2018 after its closure following September 11?", "WTC Cortlandt", "Rector Street", "South Ferry", "Chambers Street"]
    ]
}
