import unittest

from attendance.geofence import (
    ATTENDANCE_RADIUS_METERS,
    MAX_GPS_ACCURACY_METERS,
    distance_in_meters,
    nearest_office,
    valid_coordinate,
    validate_location,
)


class GeofenceTests(unittest.TestCase):
    def setUp(self):
        self.offices = [
            {"id": "test", "name": "Test Office", "latitude": 0.0, "longitude": 0.0},
            {"id": "other", "name": "Other Office", "latitude": 10.0, "longitude": 10.0},
        ]

    def test_same_coordinates_have_zero_distance(self):
        self.assertEqual(distance_in_meters(0, 0, 0, 0), 0)

    def test_haversine_measures_short_distance(self):
        distance = distance_in_meters(0, 0, 0, 0.0001)
        self.assertGreater(distance, 11)
        self.assertLess(distance, 12)

    def test_coordinate_validation_rejects_bad_values(self):
        self.assertTrue(valid_coordinate(90, 180))
        self.assertFalse(valid_coordinate(91, 0))
        self.assertFalse(valid_coordinate(True, 0))
        self.assertFalse(valid_coordinate(float("nan"), 0))

    def test_rejects_location_beyond_radius(self):
        office, error = validate_location(
            {"latitude": 0, "longitude": 0.001, "accuracyMeters": 5},
            self.offices,
        )
        self.assertIsNone(office)
        self.assertEqual(error[1], 403)
        self.assertGreater(error[0]["distanceMeters"], ATTENDANCE_RADIUS_METERS)

    def test_rejects_inaccurate_gps(self):
        office, error = validate_location(
            {"latitude": 0, "longitude": 0, "accuracyMeters": MAX_GPS_ACCURACY_METERS + 1},
            self.offices,
        )
        self.assertIsNone(office)
        self.assertEqual(error[1], 422)

    def test_accounts_for_gps_uncertainty_at_geofence_edge(self):
        office, error = validate_location(
            {"latitude": 0, "longitude": 0.0004, "accuracyMeters": 10},
            self.offices,
        )
        self.assertIsNone(office)
        self.assertEqual(error[1], 403)

    def test_chooses_nearest_registered_office(self):
        result = nearest_office(10.001, 10, self.offices)
        self.assertEqual(result["id"], "other")

    def test_accepts_location_inside_radius(self):
        office, error = validate_location(
            {"latitude": 0, "longitude": 0, "accuracyMeters": 5},
            self.offices,
        )
        self.assertIsNone(error)
        self.assertEqual(office["id"], "test")


if __name__ == "__main__":
    unittest.main()
