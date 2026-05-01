import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../storage/secure_storage.dart';
import 'api_endpoints.dart';

final dioClientProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    baseUrl: ApiEndpoints.baseUrl,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: {'Content-Type': 'application/json'},
  ));

  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await SecureStorageService.getAccessToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    },
    onError: (error, handler) async {
      if (error.response?.statusCode == 401) {
        // Tentative de refresh token
        try {
          final refreshToken = await SecureStorageService.getRefreshToken();
          if (refreshToken != null) {
            final response = await Dio().post(
              '${ApiEndpoints.baseUrl}${ApiEndpoints.refresh}',
              data: {'refresh_token': refreshToken},
            );
            final newToken = response.data['access_token'];
            await SecureStorageService.saveAccessToken(newToken);
            error.requestOptions.headers['Authorization'] = 'Bearer $newToken';
            final retryResponse = await dio.fetch(error.requestOptions);
            return handler.resolve(retryResponse);
          }
        } catch (_) {}
      }
      handler.next(error);
    },
  ));

  return dio;
});
