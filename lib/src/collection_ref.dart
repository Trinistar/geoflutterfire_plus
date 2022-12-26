import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rxdart/rxdart.dart';

import '../geoflutterfire_plus.dart';
import 'math.dart';

/// An entity to handle cloud_firestore [DocumentSnapshot] with distance from
/// given center in kilometers.
class GeoDocumentSnapshot<T> {
  GeoDocumentSnapshot({
    required this.documentSnapshot,
    required this.distanceFromCenterInKm,
  });

  /// Fetched [DocumentSnapshot].
  final DocumentSnapshot<T> documentSnapshot;

  /// Distance from center in kilometers.
  final double distanceFromCenterInKm;
}

/// Extended cloud_firestore [CollectionReference] for geo query features.
class GeoCollectionRef<T> {
  GeoCollectionRef(this._collectionReference);

  /// [CollectionReference] of target collection.
  final CollectionReference<T> _collectionReference;

  /// Detection range buffer when not strict mode.
  static const _detectionRangeBuffer = 1.02;

  /// Creates a document with provided [data].
  Future<DocumentReference<T>> add(T data) => _collectionReference.add(data);

  /// Sets the provided [data] on the document.
  Future<void> setDocument({
    required String id,
    required T data,
    bool merge = false,
  }) =>
      _collectionReference.doc(id).set(data, SetOptions(merge: merge));

  /// Deletes the document from the collection.
  Future<void> delete(String id) => _collectionReference.doc(id).delete();

  /// Sets/Updates the pair of ([latitude], [longitude]) as cloud_firestore [GeoPoint]
  /// and geohash string on the document's given [field].
  Future<void> setPoint({
    required String id,
    required String field,
    required double latitude,
    required double longitude,
  }) =>
      // Note: Remove type to enable to set the values as `Map`.
      // ignore: unnecessary_cast
      (_collectionReference.doc(id) as DocumentReference).set(
        <String, dynamic>{field: GeoFirePoint(latitude, longitude).data},
        SetOptions(merge: true),
      );

  /// Notifies of geo query results by given condition.
  ///
  /// * [center] Center point of detection.
  /// * [radiusInKm] Detection range in kilometers.
  /// * [field]
  /// * [strictMode] Whether to filter documents strictly within the bound of
  /// given radius.
  Stream<List<GeoDocumentSnapshot<T>>> within({
    required GeoFirePoint center,
    required double radiusInKm,
    required String field,
    required GeoPoint Function(T obj) geopointFrom,
    bool strictMode = false,
  }) {
    final precisionDigits = geohashDigitsFromRadius(radiusInKm);
    final centerGeoHash = center.geohash.substring(0, precisionDigits);
    final geohashes = [
      ...neighborGeohashesOf(geohash: centerGeoHash),
      centerGeoHash,
    ];

    final collectionStreams = geohashes
        .map(
          (geohash) => _collectionReference
              .orderBy('$field.geohash')
              .startAt([geohash])
              .endAt(['$geohash~'])
              .snapshots()
              .map((querySnapshot) => querySnapshot.docs),
        )
        .toList();

    final mergedCollectionStreams = Rx.combineLatest<
        List<QueryDocumentSnapshot<T>>, List<QueryDocumentSnapshot<T>>>(
      collectionStreams,
      (values) => [
        for (final queryDocumentSnapshots in values) ...queryDocumentSnapshots,
      ],
    );

    final filtered = mergedCollectionStreams.map((queryDocumentSnapshots) {
      final mappedList = queryDocumentSnapshots.map((queryDocumentSnapshot) {
        final exists = queryDocumentSnapshot.exists;
        if (!exists) {
          return null;
        }
        final fetchedData = queryDocumentSnapshot.data();
        final fetchedGeopoint = geopointFrom(fetchedData);
        final distanceFromCenterInKm = center.distanceBetweenInKm(
          latitude: fetchedGeopoint.latitude,
          longitude: fetchedGeopoint.longitude,
        );

        return GeoDocumentSnapshot(
          documentSnapshot: queryDocumentSnapshot,
          distanceFromCenterInKm: distanceFromCenterInKm,
        );
      }).toList();

      final nullableFilteredList = strictMode
          ? mappedList.where(
              (doc) =>
                  doc != null &&
                  doc.distanceFromCenterInKm <=
                      radiusInKm * _detectionRangeBuffer,
            )
          : mappedList;
      return nullableFilteredList.whereType<GeoDocumentSnapshot<T>>().toList()
        ..sort(
          (a, b) =>
              (a.distanceFromCenterInKm * 1000).toInt() -
              (b.distanceFromCenterInKm * 1000).toInt(),
        );
    });
    return filtered.asBroadcastStream();
  }
}